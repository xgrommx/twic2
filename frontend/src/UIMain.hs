{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecursiveDo           #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE CPP                   #-}

module Main where

import Prelude
import Control.Applicative           ((<*>), (<$>))
import Control.Concurrent            (forkIO, threadDelay)
import Control.Concurrent.MVar       (newEmptyMVar, putMVar, tryReadMVar)
import Control.Monad                 (void, join)
import Control.Monad.IO.Class        (liftIO)
import Control.Monad.Fix             (MonadFix)

import qualified Data.Aeson          as A
import qualified Data.ByteString.Char8 as BSL8
import qualified Data.ByteString     as BSL
import Data.Map.Strict               (Map)
import qualified Data.Map.Strict     as Map
import Data.Maybe                    (Maybe(..), isJust, fromJust)
import Data.Monoid
import qualified Data.Text           as T

import qualified Reflex              as R
import qualified Reflex.Class        as RC
import qualified Reflex.Host.App     as RHA

import qualified Data.VirtualDOM     as VD
import qualified Data.VirtualDOM.DOM as DOM

import qualified JavaScript.Web.WebSocket as WS
import qualified JavaScript.Web.MessageEvent as ME
import qualified Data.JSString      as JSS
import           GHCJS.Prim         (JSVal)

import qualified BL.Types           as BL
import  BL.Instances


-- `l` is DOM.Node in currently; polymorphic to enable other implementations
type AppContainer t m l c = (RHA.MonadAppHost t m, l ~ DOM.Node, c ~ Counter) => l -> TheApp t m l c -> m ()
type AppHost              = (forall t m l c . (l ~ DOM.Node, c ~ Counter) => AppContainer t m l c)
                         -> (forall t m l c . c ~ Counter => TheApp t m l c)
                         -> IO ()
type TheApp t m l c       = (RHA.MonadAppHost t m, MonadFix m) => m (R.Dynamic t (VD.VNode l), R.Dynamic t c)
type Sink a               = a -> IO Bool

socketUrl = "ws://localhost:3000"
-- socketUrl = "ws://echo.websocket.org"

--- Entry point ----------------------------------------------------------------

main = hostApp appContainer theApp
-- main = hostApp appContainer (counterApp 1 R.never)

--- Kernel ---------------------------------------------------------------------

hostApp :: AppHost
hostApp appContainer anApp = do
  dombody     <- VD.getBody :: IO DOM.Node
  containerEl <- (VD.createElement VD.domAPI) "div"
  (VD.appendChild VD.domAPI) containerEl dombody

  R.runSpiderHost $ RHA.hostApp (appContainer containerEl anApp)


(~>) :: RHA.MonadAppHost t m => R.Event t a -> (a -> IO b) -> m ()
(~>) ev sink = RHA.performEvent_ $ (liftIO . void . sink) <$> ev

appContainer :: AppContainer t m l c
appContainer container anApp = do
  (vdomEvents, vdomSink) <- RHA.newExternalEvent

  (dynView, _) <- anApp
  curView <- R.sample $ R.current dynView

  let initialVDom = (Just curView, Nothing)

  vdomDyn <- R.foldDyn (\new (old, _) -> (Just new, old)) initialVDom (R.updated dynView)

  (R.updated vdomDyn) ~> vdomSink
  vdomEvents ~> draw

  whenReady $ const $ vdomSink initialVDom

  where
    draw :: (l ~ DOM.Node) => (Maybe (VD.VNode l), Maybe (VD.VNode l)) -> IO ()
    draw (newVdom, oldVdom) = void . forkIO $ do
      print $ "draw " <> show newVdom
      VD.patch VD.domAPI container oldVdom newVdom

--- Userspace ------------------------------------------------------------------

redButton   = [("style", "background-color: red;   color: white; padding: 10px;")]
greenButton = [("style", "background-color: green; color: white; padding: 10px;")]
blueButton  = [("style", "background-color: blue;  color: white; padding: 10px;")]

block xs = VD.h "div" (VD.prop [("style", "display: block;")]) xs
textLabel t = VD.h "span" (VD.prop [("style", "padding: 10px;")]) [VD.text t]
errorLabel t = VD.h "span" (VD.prop [("style", "padding: 10px; color: red;")]) [VD.text t]
inlineLabel t = VD.h "span" (VD.prop [("style", "padding: 0px;")]) [VD.text t]

button label attrs listeners =
  flip VD.with listeners $
    VD.h "button" (VD.prop attrs) [VD.text label]

foreign import javascript unsafe "$1.target.value"
  jsval :: JSVal -> JSS.JSString

stringInput u =
  flip VD.with [VD.On "change" (\ev -> u . JSS.unpack . jsval $ ev)] $
    VD.h "input" (VD.prop [("type", "text"), ("style", "padding: 2px 5px; margin: 5px 0px;")]) []

panel ch = VD.h "div"
                (VD.prop [ ("class", "panel")
                         , ("style", "padding: 10px; border: 1px solid grey; width: auto; display: inline-block; margin: 5px;")])
                ch

list xs = VD.h "ul"
               (VD.prop [ ("class", "list")
                        , ("style", "text-align: left;")])
               (fmap listItem xs)

listItem x = VD.h "li"
               (VD.prop [ ("class", "list-ietm")
                        , ("style", "")])
               [x]

tweet t = panel [ author (BL.user t), body (BL.text t) ]

author a = textLabel $ T.unpack $ BL.name a

body t = block (fmap telToHtml t)

telToHtml (BL.AtUsername s) = inlineLabel s
telToHtml (BL.Link s)       = inlineLabel s
telToHtml (BL.PlainText s)  = inlineLabel s
telToHtml (BL.Hashtag s)    = inlineLabel s
telToHtml BL.Retweet        = inlineLabel "Retweet"
telToHtml (BL.Spaces s)     = inlineLabel s
telToHtml (BL.Unparsable s) = inlineLabel s

columns cs =
  VD.h "div" (VD.prop [("style", "display: flex; flex-direction: row; flex-wrap: nowrap ; justify-content: flex-start; align-items: stretch;")])
       (fmap (\(x, pctWidth) -> VD.h "div" (VD.prop [("style", "align-self: stretch; flex-basis: " <> show pctWidth <> "%;")]) [x]) cs)

subscribeToEvent ev f = RHA.performEvent_ $ fmap (liftIO . void . f) ev
subscribeToEvent' ev f = RHA.performEvent_ $ fmap f ev

whenReady f = do
  ready <- RHA.getPostBuild
  subscribeToEvent ready f

setupWebsocket :: RHA.MonadAppHost t m => String -> m (WSInterface t, R.Dynamic t (Maybe WS.WebSocket))
setupWebsocket socketUrl = do
  (wsRcvE :: R.Event t (Either String WSData), wsRcvU) <- RHA.newExternalEvent
  (wsE :: R.Event t (Maybe WS.WebSocket), wsSink) <- RHA.newExternalEvent

  x <- liftIO $ newEmptyMVar

  let wscfg = WS.WebSocketRequest (JSS.pack socketUrl) []
                                  (Just $ \ev -> putMVar x Nothing >> wsSink Nothing >> print "ws closed"  )
                                  (Just $ \ev -> (wsRcvU . decodeWSMsg $ ev) >> pure () )

  liftIO . void $ connectWS wscfg x wsSink 0

  wsD' <- R.holdDyn Nothing wsE
  subscribeToEvent' (R.ffilter (not . isJust) wsE) $
    const . liftIO . void $ connectWS wscfg x wsSink 1000000

  let wssend = \payload -> do
                  wsh <- tryReadMVar x
                  case wsh of
                    Just (Just wsh') -> WS.send (encodeWSMsg payload) wsh' >> pure (Right True)
                    otherwise        -> return $ Left "ws not ready"

  let wsi = WSInterface { ws_rcve = wsRcvE
                        , ws_send = wssend }

  return (wsi, wsD')

connectWS wscfg x wsSink delay =
  forkIO $ void $ do
    print $ "(re)connecting wensocket in " <> show delay <> "ns"
    threadDelay delay
    ws <- WS.connect wscfg
    putMVar x $ Just ws
    wsSink $ Just ws

encodeWSMsg :: WSData -> JSS.JSString
encodeWSMsg (WSData fm) = JSS.pack "error"
encodeWSMsg (WSCommand s) = JSS.pack s

decodeWSMsg :: ME.MessageEvent -> Either String WSData
decodeWSMsg m =
  case ME.getData m of
    ME.StringData s       -> WSData <$> (A.eitherDecodeStrict . BSL8.pack . JSS.unpack $ s :: Either String BL.FeedState)
    ME.BlobData _         -> Left "BlobData not supported yet"
    ME.ArrayBufferData _  -> Left "ArrayBufferData not supported yet"
--------------------------------------------------------------------------------

data TestWSBLAction = TestWS deriving (Show, Eq)

testWS :: TheApp t m l Counter
testWS = do
  (controllerE :: R.Event t TestWSBLAction, controllerU) <- RHA.newExternalEvent
  (modelE :: R.Event t (Either String WSData), modelU) <- RHA.newExternalEvent
  (inputE :: R.Event t String, inputU) <- RHA.newExternalEvent

  inputD <- R.holdDyn "" inputE
  modelD <- R.foldDyn (\x xs -> xs <> [x]) [] modelE

  (wsi, wsready) <- setupWebsocket socketUrl
  wsReady <- R.headE . R.ffilter isJust . R.updated $ wsready

  ws_rcve wsi ~> (print . mappend "Received from WS: " . show)
  ws_rcve wsi ~> modelU

  subscribeToEvent wsReady $ \_ -> ws_send wsi (WSCommand "hello ws")

  subscribeToEvent' (R.ffilter (== TestWS) controllerE) $ \x -> do
    inputVal <- R.sample $ R.current inputD
    void . liftIO $ ws_send wsi (WSCommand inputVal)

  let ownViewDyn = fmap (render controllerU inputU) modelD

  return (ownViewDyn, pure (Counter 0))

  where
    render :: Sink TestWSBLAction -> Sink String -> [Either String WSData] -> VD.VNode l
    render controllerU inputU ws =
      panel [ block [stringInput (\x -> inputU x >> pure ())]
            , block [button "Test WS" redButton [VD.On "click" (void . const (controllerU TestWS))]]
            , panel [list (fmap renderFeedItem ws)]
            ]

    renderFeedMessage (BL.TweetMessage t)       = tweet t
    renderFeedMessage (BL.UserMessage x)        = textLabel $ show x
    renderFeedMessage (BL.SettingsMessage x)    = textLabel $ show x
    renderFeedMessage (BL.FriendsListMessage x) = textLabel $ show x
    renderFeedMessage (BL.ErrorMessage x)       = textLabel $ show x

    renderFeedItem (Left s)            = errorLabel s
    renderFeedItem (Right (WSData ts)) = block $ fmap renderFeedMessage ts
    renderFeedItem (Right x)           = textLabel $ show x


--------------------------------------------------------------------------------

instance Monoid (VD.VNode l) where
  mempty      = VD.text ""
  mconcat as  = VD.h "div" (VD.prop []) as
  mappend a b = VD.h "div" (VD.prop []) [a, b]

data AppBLAction     = AddCounter | RemoveCounter | ResetAll deriving (Show, Eq)
data ChildAction     = Reset deriving (Show, Eq)
data AppCounterModel = AppCounterModel Int Int
type ViewDyn t l     = R.Dynamic t (VD.VNode l)

data WSData = WSData BL.FeedState | WSCommand String deriving (Show)

data WSInterface t = WSInterface
  { ws_send    :: WSData -> IO (Either String Bool)
  , ws_rcve    :: R.Event t (Either String WSData)
  }

theApp :: TheApp t m l Counter
theApp = do
  (controllerE :: R.Event t AppBLAction, controllerU) <- RHA.newExternalEvent
  (counterModelE :: R.Event t (Int -> Int), counterModelU) <- RHA.newExternalEvent
  (childControllerE :: R.Event t ChildAction, childControllerU) <- RHA.newExternalEvent

  subscribeToEvent (R.ffilter onlyAddRemove controllerE) $ counterModelU . updateCounter
  counterModelD <- R.foldDyn foldCounter (AppCounterModel 0 0) counterModelE    -- :: m (R.Dynamic t AppCounterModel)

  subscribeToEvent (R.ffilter (== ResetAll) controllerE) (\x -> childControllerU Reset)

  (testWSViewD, _) <- testWS

  let mas = fmap (makeCounters childControllerE) (R.updated counterModelD)      -- :: R.Event t (Map Int (Maybe (m (ViewDyn t l, R.Dynamic x))))
  as <- RHA.holdKeyAppHost (Map.empty) mas                                      -- :: m (R.Dynamic t (Map Int (ViewDyn t l, R.Dynamic x)))

  let as' = fmap Map.elems as                                                   -- :: R.Dynamic t [(ViewDyn t l, R.Dynamic x)]

      xs = fmap (fmap fst) as'                                                  --  R.Dynamic t [ViewDyn t l]
      ys = fmap (fmap snd) as'                                                  --  R.Dynamic t [R.Dynamic x]

      ys' = fmap mconcat ys                                                     -- R.Dynamic t [R.Dynamic (Counter Int)]
      jys = join ys'                                                            -- R.Dynamic (Counter Int)

      as'' = fmap mconcat xs                                                    -- :: R.Dynamic t (ViewDyn t l)
      jas  = join as''                                                          -- :: R.Dynamic t (VD.VNode l)

      allCounters = (,) <$> counterModelD <*> jys

      ownViewDyn    = fmap (render controllerU) allCounters                     -- :: R.Dynamic t (VD.VNode l)
      resultViewDyn = layout <$> ownViewDyn <*> testWSViewD <*> jas             -- :: R.Dynamic t (VD.VNode l)

  return (resultViewDyn, pure (Counter 0))

  where
    layout own testws counters =
      columns [(testws, 100)]

    onlyAddRemove AddCounter    = True
    onlyAddRemove RemoveCounter = True
    onlyAddRemove _             = False

    updateCounter AddCounter    = (+1)
    updateCounter RemoveCounter = (\x -> if x - 1 < 0 then 0 else x - 1)
    updateCounter _             = (+0)

    foldCounter :: (Int -> Int) -> AppCounterModel -> AppCounterModel
    foldCounter op (AppCounterModel x _) = AppCounterModel (op x) x

    makeCounters :: (RHA.MonadAppHost t m, Counter ~ c) =>
                    R.Event t ChildAction -> AppCounterModel -> (Map Int (Maybe (m (ViewDyn t l, R.Dynamic t c))))
    makeCounters childControllerE (AppCounterModel new old) =
      if new >= old
        then Map.singleton new (Just $ counterApp new childControllerE)
        else Map.singleton old Nothing

    render :: Sink AppBLAction -> (AppCounterModel, Counter) -> VD.VNode l
    render controllerU (AppCounterModel new old, Counter total) =
      panel [ panel [ button "-" greenButton [VD.On "click" (void . const (controllerU RemoveCounter))]
                    , textLabel $ "Counters: " <> show new <> " (was: " <> show old <> ")"
                    , button "+" greenButton [VD.On "click" (void . const (controllerU AddCounter))]
                    ]
            , panel [ textLabel $ "Total counters sum: " <> show total
                    , button "Reset all" redButton [VD.On "click" (void . const (controllerU ResetAll))]
                    ]
            ]

--------------------------------------------------------------------------------

data CounterBLAction = Inc | Dec deriving (Show)
data Counter         = Counter Int deriving (Show)

instance Monoid Counter where
  mempty = Counter 0
  mappend (Counter a) (Counter b) = Counter (a + b)

counterApp :: Int -> R.Event t ChildAction -> TheApp t m l Counter
counterApp id_ cmdE = do
  (blEvents, blSink) <- RHA.newExternalEvent
  (modelEvents :: R.Event t (Int -> Int), modelSink) <- RHA.newExternalEvent

  subscribeToEvent cmdE $ \ev -> case ev of
    Reset -> modelSink (*0) >> pure ()

  subscribeToEvent blEvents $ \ev -> case ev of
    Inc -> modelSink (+1)
    Dec -> modelSink (\x -> x - 1)

  modelDyn <- R.foldDyn (\op (Counter prev) -> Counter (op prev)) (Counter 0) modelEvents
  let dynView = fmap (render blSink) modelDyn

  return (dynView, modelDyn)

  where
    render :: Sink CounterBLAction -> Counter -> VD.VNode l
    render blSink (Counter c) =
      panel [ button "-" blueButton [VD.On "click" (void . const (blSink Dec))]
            , textLabel $ "Counter #" <> show id_ <> ": " <> show c
            , button "+" blueButton [VD.On "click" (void . const (blSink Inc))]
            ]
