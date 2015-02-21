{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}
module Broch.Server.Internal
    ( Handler
    , Router
    , routerToApp
    , postParams
    , queryParams
    , postParam
    , queryParam
    , httpMethod
    , requireMethod
    , request
    , body
    , redirect
    , redirectExternal
    , status
    , setHeader
    , text
    , json
    , html
    , rawBytes
    , complete
    , sessionLookup
    , sessionInsert
    , sessionDelete
    , invalidateSession
    , notFound
    , methodNotAllowed
    )
where

import Debug.Trace

import Control.Applicative
import Control.Error
import Control.Exception (SomeException, catch)
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.State
import qualified Data.Aeson as A
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Parse
import Text.Blaze.Html (Html)
import Text.Blaze.Html.Renderer.Utf8 (renderHtml)

import qualified Broch.Server.Session as S

data HandlerResult
    = Redirect ByteString
    | RedirectExternal ByteString
    | ResponseComplete
    | HandlerError ByteString
      deriving (Show, Eq)



-- Request handler monad
type Handler a = EitherT HandlerResult (ReaderT RequestData (StateT ResponseState IO)) a

type Router = [Text] -> Handler ()

type Params = M.Map Text [Text]

data RequestData = RequestData
    { waiReq   :: !Request
    , method   :: !StdMethod
    , qps      :: !Params
    , pps      :: !Params
    }

data ResponseState = ResponseState
    { resStatus  :: !Status
    , resHeaders :: !ResponseHeaders
    , resBody    :: !BL.ByteString
    , resSession :: !(Maybe S.Session)
    }

routerToApp :: S.LoadSession -> Text -> Router -> Application
routerToApp loadSesh baseUrl route req respond = do
    pParams <- fst <$> parseRequestBody lbsBackEnd req

    response <- case httpMeth of
        Left badM -> return $ responseLBS methodNotAllowed405 [] $ BL.fromStrict $ B.concat["Unknown or unsupported HTTP method: ", badM]
        Right m   -> do
            let rd = RequestData
                      { waiReq  = req
                      , method  = m
                      , qps     = toMap $ (\(n, v) -> (n, fromMaybe "" v)) <$> queryString req
                      , pps     = toMap pParams
                      }

            runHandler rd (route $ pathInfo req)
                `catch` \(e :: SomeException) -> do
                    let errMsg = BLC.pack $ "Internal error: " ++ show e
                    BLC.putStrLn errMsg
                    return $ responseLBS internalServerError500 [] errMsg
    respond response
  where
    redirectFull url hdrs = traceShow url $ responseLBS status302 ((hLocation, url) : hdrs) ""
    httpMeth              = parseMethod $ requestMethod req

    runHandler :: RequestData -> Handler () -> IO Response
    runHandler rd h  = do
        (initSesh, saveSesh) <- loadSesh req
        let initRes = ResponseState status200 [] "" initSesh
        (result, res) <- runStateT (runReaderT (runEitherT h) rd) initRes
        seshHdr <- saveSesh $ resSession res
        let hdrs = case seshHdr of
                      Nothing -> resHeaders res
                      Just sh -> sh : resHeaders res
        return $ case result of
            Left ResponseComplete -> responseLBS (resStatus res) hdrs (resBody res)
            Left (Redirect url)   -> redirectFull (B.concat [TE.encodeUtf8 baseUrl, url]) hdrs
            Left (RedirectExternal url) -> redirectFull url hdrs
            Left (HandlerError msg) -> responseLBS internalServerError500 hdrs (BL.fromStrict msg)
            Right _ -> error "Not handled"

toMap :: [(ByteString, ByteString)] -> Params
toMap = M.unionsWith (++) . map (\(x, y) -> M.singleton (TE.decodeUtf8 x) [TE.decodeUtf8 y])

-- Handler functions

-- Accessing requests

request :: Handler Request
request = asks waiReq

body :: Handler BL.ByteString
body = request >>= liftIO . strictRequestBody

postParams :: Handler Params
postParams = asks pps

queryParams :: Handler Params
queryParams = asks qps

postParam :: Text -> Handler Text
postParam name = postParams >>= lookupParam name

queryParam :: Text -> Handler Text
queryParam name = queryParams >>= lookupParam name

lookupParam :: Text -> Params -> Handler Text
lookupParam name params = case M.lookup name params of
    Just [v] -> return v
    _        -> throwError $ HandlerError $ B.concat ["Missing or duplicate parameter", TE.encodeUtf8 name]

httpMethod :: Handler StdMethod
httpMethod = asks method

requireMethod :: StdMethod -> Handler ()
requireMethod m = do
    actualMethod <- httpMethod
    unless (m == actualMethod) $ status methodNotAllowed405 >> text "Method not supported"

-- Responses

-- Redirect to an internal location within the same site
redirect :: ByteString -> Handler a
redirect = throwError . Redirect

redirectExternal :: ByteString -> Handler a
redirectExternal = throwError . RedirectExternal

status :: Status -> Handler ()
status s = modify $ \rs -> rs { resStatus = s }

setHeader :: HeaderName -> ByteString -> Handler ()
setHeader name value = modify $ \rs -> rs { resHeaders = (name, value) : resHeaders rs }

setContentType :: ByteString -> Handler ()
setContentType = setHeader "Content-Type"

rawBytes :: BL.ByteString -> Handler ()
rawBytes b = modify (\rs -> rs { resBody = b }) >> throwError ResponseComplete

text :: Text -> Handler ()
text t = setContentType "text/plain; charset=utf-8" >> (rawBytes . BL.fromStrict $ TE.encodeUtf8 t)

complete :: Handler ()
complete = throwError ResponseComplete

json :: A.ToJSON a => a -> Handler ()
json j = setContentType "application/json" >> rawBytes (A.encode j)

html :: Html -> Handler ()
html h = setContentType "text/html; charset=utf-8" >> rawBytes (renderHtml h)

sessionLookup :: ByteString -> Handler (Maybe ByteString)
sessionLookup k = gets $ \rs -> maybe Nothing (`S.lookup` k) $ resSession rs

sessionInsert :: ByteString -> ByteString -> Handler ()
sessionInsert k v = modify $ \rs -> let session = fromMaybe S.empty $ resSession rs
                                    in  rs { resSession = Just $ S.insert session k v }

sessionDelete :: ByteString -> Handler ()
sessionDelete k = do
    rs <- get
    case resSession rs of
        Nothing -> return ()
        Just s  -> put rs { resSession = Just $ S.delete s k }

invalidateSession :: Handler ()
invalidateSession = modify $ \rs -> rs { resSession = Nothing }

methodNotAllowed :: Handler ()
methodNotAllowed = status methodNotAllowed405 >> complete

notFound :: Handler ()
notFound = status notFound404 >> complete