{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Run (
    checkCtxFinished,
    recvDataAssert,
    byeBye,
    runTLSPipe,
    runTLSPipeSimple,
    runTLSPipeSimple13,
    runTLSPipeSimpleKeyUpdate,
    runTLSPipePredicate,
    runTLSPipeCapture13,
    runTLSPipeFailure,
    readClientSessionRef,
    twoSessionRefs,
    twoSessionManagers,
    setPairParamsSessionManagers,
    setPairParamsSessionResuming,
    oneSessionTicket,
) where

import Codec.Serialise
import Control.Applicative
import Control.Concurrent
import Control.Concurrent.Async
import qualified Control.Exception as E
import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Default.Class
import Data.Either
import Data.IORef
import Data.Maybe
import Network.TLS
import Network.TLS.Internal
import System.Timeout
import Test.Hspec
import Test.QuickCheck

import Arbitrary
import PipeChan

type ClinetWithInput = Chan ByteString -> Context -> IO ()
type ServerWithOutput = Context -> Chan [ByteString] -> IO ()

----------------------------------------------------------------

runTLSPipe
    :: (ClientParams, ServerParams)
    -> ClinetWithInput
    -> ServerWithOutput
    -> IO ()
runTLSPipe = runTLSPipeN 1

runTLSPipeN
    :: Int
    -> (ClientParams, ServerParams)
    -> ClinetWithInput
    -> ServerWithOutput
    -> IO ()
runTLSPipeN n params tlsClient tlsServer = do
    inputChan <- newChan
    outputChan <- newChan
    -- generate some data to send
    ds <- replicateM n $ B.pack <$> generate (someWords8 256)
    forM_ ds $ writeChan inputChan
    -- run client and server
    (cCtx, sCtx) <- newPairContext params
    concurrently_ (server sCtx outputChan) (client inputChan cCtx)
    -- read result
    m_dsres <- timeout 60000000 $ readChan outputChan -- 60 sec
    case m_dsres of
        Nothing -> error "timed out"
        Just dsres -> dsres `shouldBe` ds
  where
    server sCtx outputChan =
        E.catch
            (tlsServer sCtx outputChan)
            (printAndRaise "server" (serverSupported $ snd params))
    client inputChan cCtx =
        E.catch
            (tlsClient inputChan cCtx)
            (printAndRaise "client" (clientSupported $ fst params))
    printAndRaise :: String -> Supported -> E.SomeException -> IO ()
    printAndRaise s supported e = do
        putStrLn $
            s
                ++ " exception: "
                ++ show e
                ++ ", supported: "
                ++ show supported
        E.throwIO e

----------------------------------------------------------------

runTLSPipeSimple :: (ClientParams, ServerParams) -> IO ()
runTLSPipeSimple params = runTLSPipePredicate params (const True)

runTLSPipePredicate
    :: (ClientParams, ServerParams) -> (Maybe Information -> Bool) -> IO ()
runTLSPipePredicate params p = runTLSPipe params tlsClient tlsServer
  where
    tlsClient queue ctx = do
        handshake ctx
        checkCtxFinished ctx
        checkInfoPredicate ctx
        d <- readChan queue
        sendData ctx (L.fromChunks [d])
        byeBye ctx
    tlsServer ctx queue = do
        handshake ctx
        checkCtxFinished ctx
        checkInfoPredicate ctx
        d <- recvData ctx
        writeChan queue [d]
        bye ctx
    checkInfoPredicate ctx = do
        minfo <- contextGetInformation ctx
        unless (p minfo) $
            fail ("unexpected information: " ++ show minfo)

runTLSPipeSimple13
    :: (ClientParams, ServerParams)
    -> HandshakeMode13
    -> Maybe ByteString
    -> IO ()
runTLSPipeSimple13 params mode mEarlyData = runTLSPipe params tlsClient tlsServer
  where
    tlsClient queue ctx = do
        handshake ctx
        checkCtxFinished ctx
        d <- readChan queue
        sendData ctx (L.fromChunks [d])
        minfo <- contextGetInformation ctx
        (minfo >>= infoTLS13HandshakeMode) `shouldBe` Just mode
        byeBye ctx
    tlsServer ctx queue = do
        handshake ctx
        case mEarlyData of
            Nothing -> return ()
            Just ed -> do
                let ls = chunkLengths (B.length ed)
                chunks <- replicateM (length ls) $ recvData ctx
                (map B.length chunks, B.concat chunks) `shouldBe` (ls, ed)
        d <- recvData ctx
        checkCtxFinished ctx
        writeChan queue [d]
        minfo <- contextGetInformation ctx
        (minfo >>= infoTLS13HandshakeMode) `shouldBe` Just mode
        bye ctx

chunkLengths :: Int -> [Int]
chunkLengths len
    | len > 16384 = 16384 : chunkLengths (len - 16384)
    | len > 0 = [len]
    | otherwise = []

runTLSPipeCapture13
    :: (ClientParams, ServerParams) -> IO ([Handshake13], [Handshake13])
runTLSPipeCapture13 params = do
    sRef <- newIORef []
    cRef <- newIORef []
    runTLSPipe params (tlsClient cRef) (tlsServer sRef)
    sReceived <- readIORef sRef
    cReceived <- readIORef cRef
    return (reverse sReceived, reverse cReceived)
  where
    tlsClient ref queue ctx = do
        installHook ctx ref
        handshake ctx
        checkCtxFinished ctx
        d <- readChan queue
        sendData ctx (L.fromChunks [d])
        byeBye ctx
    tlsServer ref ctx queue = do
        installHook ctx ref
        handshake ctx
        checkCtxFinished ctx
        d <- recvData ctx
        writeChan queue [d]
        bye ctx
    installHook ctx ref =
        let recv hss = modifyIORef ref (hss :) >> return hss
         in contextHookSetHandshake13Recv ctx recv

runTLSPipeSimpleKeyUpdate :: (ClientParams, ServerParams) -> IO ()
runTLSPipeSimpleKeyUpdate params = runTLSPipeN 3 params tlsClient tlsServer
  where
    tlsClient queue ctx = do
        handshake ctx
        checkCtxFinished ctx
        d0 <- readChan queue
        sendData ctx (L.fromChunks [d0])
        d1 <- readChan queue
        sendData ctx (L.fromChunks [d1])
        req <- generate $ elements [OneWay, TwoWay]
        _ <- updateKey ctx req
        d2 <- readChan queue
        sendData ctx (L.fromChunks [d2])
        byeBye ctx
    tlsServer ctx queue = do
        handshake ctx
        checkCtxFinished ctx
        d0 <- recvData ctx
        req <- generate $ elements [OneWay, TwoWay]
        _ <- updateKey ctx req
        d1 <- recvData ctx
        d2 <- recvData ctx
        writeChan queue [d0, d1, d2]
        bye ctx

----------------------------------------------------------------

runTLSPipeFailure
    :: (ClientParams, ServerParams)
    -> (Context -> IO c)
    -> (Context -> IO s)
    -> IO ()
runTLSPipeFailure params hsClient hsServer = do
    (cRes, sRes) <- initiateDataPipe params tlsServer tlsClient
    cRes `shouldSatisfy` isLeft
    sRes `shouldSatisfy` isLeft
  where
    tlsServer ctx = do
        _ <- hsServer ctx
        checkCtxFinished ctx
        minfo <- contextGetInformation ctx
        byeBye ctx
        return $ "server success: " ++ show minfo
    tlsClient ctx = do
        _ <- hsClient ctx
        checkCtxFinished ctx
        minfo <- contextGetInformation ctx
        byeBye ctx
        return $ "client success: " ++ show minfo

initiateDataPipe
    :: (ClientParams, ServerParams)
    -> (Context -> IO a)
    -> (Context -> IO b)
    -> IO (Either E.SomeException b, Either E.SomeException a)
initiateDataPipe params tlsServer tlsClient = do
    -- initial setup
    (cCtx, sCtx) <- newPairContext params

    async (tlsServer sCtx) >>= \sAsync ->
        async (tlsClient cCtx) >>= \cAsync -> do
            sRes <- waitCatch sAsync
            cRes <- waitCatch cAsync
            return (cRes, sRes)

----------------------------------------------------------------

readClientSessionRef :: (IORef mclient, IORef mserver) -> IO mclient
readClientSessionRef refs = readIORef (fst refs)

twoSessionRefs :: IO (IORef (Maybe client), IORef (Maybe server))
twoSessionRefs = (,) <$> newIORef Nothing <*> newIORef Nothing

-- | simple session manager to store one session id and session data for a single thread.
-- a Real concurrent session manager would use an MVar and have multiples items.
oneSessionManager :: IORef (Maybe (SessionID, SessionData)) -> SessionManager
oneSessionManager ref =
    SessionManager
        { sessionResume = \myId -> readIORef ref >>= maybeResume False myId
        , sessionResumeOnlyOnce = \myId -> readIORef ref >>= maybeResume True myId
        , sessionEstablish = \myId dat -> writeIORef ref (Just (myId, dat)) >> return Nothing
        , sessionInvalidate = \_ -> return ()
        , sessionUseTicket = False
        }
  where
    maybeResume onlyOnce myId (Just (sid, sdata))
        | sid == myId = when onlyOnce (writeIORef ref Nothing) >> return (Just sdata)
    maybeResume _ _ _ = return Nothing

twoSessionManagers
    :: (IORef (Maybe (SessionID, SessionData)), IORef (Maybe (SessionID, SessionData)))
    -> (SessionManager, SessionManager)
twoSessionManagers (cRef, sRef) = (oneSessionManager cRef, oneSessionManager sRef)

setPairParamsSessionManagers
    :: (SessionManager, SessionManager)
    -> (ClientParams, ServerParams)
    -> (ClientParams, ServerParams)
setPairParamsSessionManagers (clientManager, serverManager) (clientParams, serverParams) = (nc, ns)
  where
    nc =
        clientParams
            { clientShared = updateSessionManager clientManager $ clientShared clientParams
            }
    ns =
        serverParams
            { serverShared = updateSessionManager serverManager $ serverShared serverParams
            }
    updateSessionManager manager shared = shared{sharedSessionManager = manager}

----------------------------------------------------------------

setPairParamsSessionResuming
    :: (SessionID, SessionData)
    -> (ClientParams, ServerParams)
    -> (ClientParams, ServerParams)
setPairParamsSessionResuming sessionStuff (clientParams, serverParams) =
    ( clientParams{clientWantSessionResume = Just sessionStuff}
    , serverParams
    )

instance Serialise Group
instance Serialise Version
instance Serialise TLS13TicketInfo
instance Serialise SessionFlag
instance Serialise SessionData

oneSessionTicket :: SessionManager
oneSessionTicket =
    SessionManager
        { sessionResume = resume
        , sessionResumeOnlyOnce = resume
        , sessionEstablish = \_ dat -> return $ Just $ L.toStrict $ serialise dat
        , sessionInvalidate = \_ -> return ()
        , sessionUseTicket = True
        }

resume :: Ticket -> IO (Maybe SessionData)
resume ticket
    | isTicket ticket = return $ Just $ deserialise $ L.fromStrict ticket
    | otherwise = return Nothing

checkCtxFinished :: Context -> IO ()
checkCtxFinished ctx = do
    mUnique <- getTLSUnique ctx
    mExporter <- getTLSExporter ctx
    when (isNothing (mUnique <|> mExporter)) $
        fail "unexpected channel binding"

recvDataAssert :: Context -> ByteString -> IO ()
recvDataAssert ctx expected = do
    got <- recvData ctx
    got `shouldBe` expected

----------------------------------------------------------------

debug :: Bool
debug = False

newPairContext
    :: (ClientParams, ServerParams) -> IO (Context, Context)
newPairContext (cParams, sParams) = do
    pipe <- newPipe
    _ <- runPipe pipe
    let noFlush = return ()
    let noClose = return ()

    let cBackend = Backend noFlush noClose (writePipeC pipe) (readPipeC pipe)
    let sBackend = Backend noFlush noClose (writePipeS pipe) (readPipeS pipe)
    cCtx' <- contextNew cBackend cParams
    sCtx' <- contextNew sBackend sParams

    contextHookSetLogging cCtx' (logging "client: ")
    contextHookSetLogging sCtx' (logging "server: ")

    return (cCtx', sCtx')
  where
    logging pre =
        if debug
            then
                def
                    { loggingPacketSent = putStrLn . ((pre ++ ">> ") ++)
                    , loggingPacketRecv = putStrLn . ((pre ++ "<< ") ++)
                    }
            else def

----------------------------------------------------------------

-- Terminate the write direction and wait to receive the peer EOF.  This is
-- necessary in situations where we want to confirm the peer status, or to make
-- sure to receive late messages like session tickets.  In the test suite this
-- is used each time application code ends the connection without prior call to
-- 'recvData'.
byeBye :: Context -> IO ()
byeBye ctx = do
    bye ctx
    bs <- recvData ctx
    unless (B.null bs) $ fail "byeBye: unexpected application data"
