{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

module Servant.EventStream
  ( ServerSentEvents
  , EventStream
  , EventSource
  , eventSource
  , jsForAPI
  )
where

import Control.Lens
import Data.Binary.Builder                  (toLazyByteString)
import qualified Data.Text                  as Text
import qualified Data.Text.Encoding         as Text
import GHC.Generics                         (Generic)
import Network.HTTP.Media                   ((//), (/:))
import Network.Wai.EventSource              (ServerEvent(..))
import Network.Wai.EventSource.EventStream  (eventToBuilder)
import qualified Pipes
import Pipes                                (X, (>->), await, yield)
import Servant
import Servant.Foreign
import Servant.Foreign.Internal             (_FunctionName)
import Servant.JS.Internal
import Servant.Pipes                        (pipesToSourceIO)

newtype ServerSentEvents
  = ServerSentEvents (Stream Get 200 NoFraming EventStream EventSource)
  deriving (Generic, HasLink)

instance HasServer ServerSentEvents context where
  type ServerT ServerSentEvents m = ServerT (StreamGet NoFraming EventStream EventSource) m
  route Proxy = route (Proxy :: Proxy (StreamGet NoFraming EventStream EventSource))
  hoistServerWithContext Proxy = hoistServerWithContext (Proxy :: Proxy (StreamGet NoFraming EventStream EventSource))

instance  (HasForeignType lang ftype EventSource)
  => HasForeign lang ftype ServerSentEvents where
  type Foreign ftype ServerSentEvents = Req ftype

  foreignFor lang Proxy Proxy req =
    req & reqFuncName . _FunctionName %~ (methodLC :)
        & reqMethod .~ method
        & reqReturnType .~ Just retType
   where
    retType  = typeFor lang (Proxy :: Proxy ftype) (Proxy :: Proxy EventSource)
    method   = reflectMethod (Proxy :: Proxy 'GET)
    methodLC = Text.toLower $ Text.decodeUtf8 method

data EventStream

instance Accept EventStream where
  contentType _ = "text" // "event-stream" /: ("charset", "utf-8")

type EventSource = SourceIO ServerEvent

instance MimeRender EventStream ServerEvent where
  mimeRender _ = maybe "" toLazyByteString . eventToBuilder

eventSource :: Pipes.Proxy X () () ServerEvent IO () -> EventSource
eventSource prod = pipesToSourceIO (prod >-> yieldUntilClose)
 where
  yieldUntilClose = do
    e <- await
    case e of
      CloseEvent -> return ()
      _ -> yield e >> yieldUntilClose

jsForAPI :: (HasForeign NoTypes NoContent api, GenerateList NoContent (Foreign NoContent api))
         => Proxy api
         -> Text.Text
jsForAPI p =
  gen (listFromAPI (Proxy :: Proxy NoTypes) (Proxy :: Proxy NoContent) p)
   where
    gen :: [Req NoContent] -> Text.Text
    gen = mconcat . map genEventSource

    genEventSource :: Req NoContent -> Text.Text
    genEventSource req =
         fname <> " = function(conf)\n"
      <> "{\n"
      <> " return (new EventSource(" <> url <> ", conf));\n"
      <> "}\n"
     where
      fname = "var " <> (toValidFunctionName (camelCase $ req ^. reqFuncName))
      url = if url' == "'" then "'/'" else url'
      url' = "'" <> urlArgs
      urlArgs = jsSegments $ req ^.. reqUrl.path.traverse