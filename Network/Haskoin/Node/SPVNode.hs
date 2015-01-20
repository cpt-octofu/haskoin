{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TemplateHaskell #-}
module Network.Haskoin.Node.SPVNode 
( SPVNode(..)
, SPVSession(..)
, SPVRequest( BloomFilterUpdate, PublishTx, NodeRescan )
, SPVData(..)
, withAsyncSPV
, processBloomFilter
)
where

import Control.Applicative ((<$>))
import Control.Monad ( when, unless, forM, forM_, foldM, forever, liftM)
import Control.Monad.Trans (liftIO)
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.Async (Async, withAsync)
import qualified Control.Monad.State as S (gets, modify)
import Control.Monad.Logger (logInfo, logWarn, logDebug, logError)

import qualified Data.Text as T (pack)
import Data.Maybe (isJust, isNothing, fromJust, catMaybes, fromMaybe)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.List (nub, partition, delete, (\\))
import Data.Conduit.TMChan (TBMChan, writeTBMChan)
import qualified Data.Map as M 
    ( Map, member, delete, lookup, fromList, fromListWith
    , keys, elems, toList, toAscList, empty, map, filter
    , adjust, update, singleton, unionWith
    )

import Network.Haskoin.Block
import Network.Haskoin.Crypto
import Network.Haskoin.Transaction.Types
import Network.Haskoin.Network
import Network.Haskoin.Node.Bloom
import Network.Haskoin.Node.Types
import Network.Haskoin.Node.Message
import Network.Haskoin.Node.PeerManager
import Network.Haskoin.Node.Peer

data SPVRequest 
    = BloomFilterUpdate !BloomFilter
    | PublishTx !Tx
    | NodeRescan !Timestamp
    | Heartbeat

data SPVSession = SPVSession
    { -- Peer currently synchronizing the block headers
      spvSyncPeer :: !(Maybe RemoteHost)
      -- Latest bloom filter provided by the wallet
    , spvBloom :: !(Maybe BloomFilter)
      -- Block hashes that have to be downloaded
    , blocksToDwn :: !(M.Map BlockHeight [BlockHash])
      -- Received merkle blocks pending to be sent to the wallet
    , receivedMerkle :: !(M.Map BlockHeight [DecodedMerkleBlock])
      -- Transactions that have not been sent in a merkle block.
      -- We stall solo transactions until the merkle blocks are synced.
    , soloTxs :: ![Tx]
      -- Transactions from users that need to be broadcasted
    , pendingTxBroadcast :: ![Tx]
      -- This flag is set if the wallet triggered a rescan.
      -- The rescan can only be executed if no merkle block are still
      -- being downloaded.
    , pendingRescan :: !(Maybe Timestamp)
      -- Do not request merkle blocks with a timestamp before the
      -- fast catchup time.
    , fastCatchup :: !Timestamp
      -- Block hashes that a peer advertised to us but we haven't linked them
      -- yet to our chain. We use this list to update the peer height once
      -- those blocks are linked.
    , peerBroadcastBlocks :: !(M.Map RemoteHost [BlockHash])
      -- Inflight merkle block requests for each peer
    , peerInflightMerkles :: 
        !(M.Map RemoteHost [((BlockHeight, BlockHash), Timestamp)])
      -- Inflight transaction requests for each peer. We are waiting for
      -- the GetData response. We stall merkle blocks if there are pending
      -- transaction downloads.
    , peerInflightTxs :: !(M.Map RemoteHost [(TxHash, Timestamp)])
    }

data SPVData t = SPVData
    { spvSession :: SPVSession
    , spvData    :: t
    }

type SPVHandle a t = MngrHandle a (SPVData t)

class (BlockHeaderStore s, Network a) => SPVNode a s t | t -> s where
    runHeaderChain :: s b -> SPVHandle a t b
    spvImportTxs :: [Tx] -> SPVHandle a t ()
    spvImportMerkleBlock :: BlockChainAction -> [TxHash] -> SPVHandle a t ()

instance SPVNode a s t => PeerManager a SPVRequest (SPVData t) where
    initNode = spvInitNode
    nodeRequest r = spvNodeRequest r
    peerHandshake remote ver = spvPeerHandshake remote ver
    peerDisconnect remote = spvPeerDisconnect remote
    startPeer _ _ = return ()
    restartPeer _ = return ()
    peerMessage remote msg = spvPeerMessage remote msg
    peerMerkleBlock remote dmb = spvPeerMerkleBlock remote dmb

withAsyncSPV :: SPVNode a s t
             => a
             -> [(String, Int)] 
             -> Timestamp
             -> t
             -> (TBMChan SPVRequest -> Async () -> IO ())
             -> IO ()
withAsyncSPV net hosts fc t f = do
    let session = SPVSession
            { spvSyncPeer = Nothing
            , spvBloom = Nothing
            , blocksToDwn = M.empty
            , receivedMerkle = M.empty
            , soloTxs = []
            , pendingTxBroadcast = []
            , pendingRescan = Nothing
            , fastCatchup = fc
            , peerBroadcastBlocks = M.empty
            , peerInflightMerkles = M.empty
            , peerInflightTxs = M.empty
            }

    -- Launch PeerManager main loop
    withAsyncNode net hosts (SPVData session t) $ \rChan a -> 
        -- Launch heartbeat thread to monitor stalled requests
        withAsync (heartbeat rChan) $ \_ -> f rChan a

heartbeat :: TBMChan SPVRequest -> IO ()
heartbeat rChan = forever $ do
    threadDelay $ 1000000 * 120 -- Sleep for 2 minutes
    atomically $ writeTBMChan rChan Heartbeat

spvPeerMessage :: SPVNode a s t => RemoteHost -> Message a -> SPVHandle a t ()
spvPeerMessage remote msg = case msg of
    MHeaders headers -> processHeaders remote headers
    MInv inv -> processInv remote inv
    MTx tx -> processTx remote tx
    _ -> return ()

spvNodeRequest :: SPVNode a s t => SPVRequest -> SPVHandle a t ()
spvNodeRequest req = case req of
    BloomFilterUpdate bf -> processBloomFilter bf
    PublishTx tx -> publishTx tx
    NodeRescan ts -> processRescan ts
    Heartbeat -> heartbeatMonitor

spvInitNode :: forall a s t. SPVNode a s t => SPVHandle a t ()
spvInitNode = do
    fc <- spvGets fastCatchup
    -- Initialize the block header database
    runHeaderChain $ initHeaderChain (undefined :: a) fc
    -- Set the block hashes that need to be downloaded
    spvModify $ \s -> s{ blocksToDwn = M.empty }
    addBlocksToDwn =<< runHeaderChain blocksToDownload

{- Peer events -}

spvPeerHandshake :: SPVNode a s t => RemoteHost -> Version -> SPVHandle a t ()
spvPeerHandshake remote ver = do
    -- Send a bloom filter if we have one
    bloomM <- spvGets spvBloom
    let filterLoad = MFilterLoad $ FilterLoad $ fromJust bloomM
    when (isJust bloomM) $ sendMessage remote filterLoad

    -- Send wallet transactions that are pending a network broadcast
    -- TODO: Is it enough just to broadcast to 1 peer ?
    -- TODO: Should we send an INV message first ?
    pendingTxs <- spvGets pendingTxBroadcast
    forM_ pendingTxs $ \tx -> sendMessage remote $ MTx tx
    spvModify $ \s -> s{ pendingTxBroadcast = [] }

    -- Send a GetHeaders regardless if there is already a peerSync. This peer
    -- could still be faster and become the new peerSync.
    sendGetHeaders remote True 0x00

    -- Trigger merkle block downloads if some are pending
    downloadBlocks remote

    logPeerSynced remote ver

spvPeerDisconnect :: SPVNode a s t => RemoteHost -> SPVHandle a t ()
spvPeerDisconnect remote = do
    remotePeers <- liftM (delete remote) getPeerKeys

    peerBlockMap <- spvGets peerBroadcastBlocks
    peerMerkleMap <- spvGets peerInflightMerkles
    peerTxMap <- spvGets peerInflightTxs

    -- Inflight merkle blocks are sent back to the download queue
    let toDwn = map fst $ fromMaybe [] $ M.lookup remote peerMerkleMap
    unless (null toDwn) $ do
        $(logDebug) $ T.pack $ unwords
            [ "Peer had inflight merkle blocks. Adding them to download queue:"
            , "[", unwords $ 
                map (encodeBlockHashLE . snd) toDwn
            , "]"
            ]
        -- Add the block hashes to the download queue
        addBlocksToDwn toDwn
        -- Request new merkle block downloads
        forM_ remotePeers downloadBlocks

    -- Remove any state related to this remote peer
    spvModify $ \s -> 
        s{ peerBroadcastBlocks = M.delete remote peerBlockMap
         , peerInflightMerkles = M.delete remote peerMerkleMap
         , peerInflightTxs     = M.delete remote peerTxMap
         }

    -- Find a new block header synchronizing peer
    syn <- spvGets spvSyncPeer
    when (syn == Just remote) $ do
        $(logInfo) "Finding a new peer to synchronize the block headers"
        spvModify $ \s -> s{ spvSyncPeer = Nothing }
        forM_ remotePeers $ \r -> sendGetHeaders r True 0x00

{- Network events -}

processHeaders :: forall a s t. SPVNode a s t
               => RemoteHost -> Headers -> SPVHandle a t ()
processHeaders remote (Headers hs) = do
    adjustedTime <- liftM round $ liftIO getPOSIXTime
    -- Save best work before the header import
    workBefore <- liftM nodeChainWork $ runHeaderChain getBestBlockHeader

    -- Import the headers into the header chain
    newBlocks <- liftM catMaybes $ forM (map fst hs) $ \bh -> do
        res <- runHeaderChain $
            connectBlockHeader (undefined :: a) bh adjustedTime
        case res of
            AcceptHeader n -> return $ Just n
            HeaderAlreadyExists n -> do
                $(logWarn) $ T.pack $ unwords
                    [ "Block header already exists at height"
                    , show $ nodeHeaderHeight n
                    , "["
                    , encodeBlockHashLE $ nodeBlockHash n
                    , "]"
                    ]
                return Nothing
            RejectHeader err -> do
                $(logError) $ T.pack err
                return Nothing
    -- Save best work after the header import
    workAfter <- liftM nodeChainWork $ runHeaderChain getBestBlockHeader

    -- Add blocks hashes to the download queue
    let f n   = (nodeHeaderHeight n, nodeBlockHash n)
        toDwn = filter (not . nodeHaveBlock) newBlocks
    addBlocksToDwn $ map f toDwn

    -- Adjust the height of peers that sent us INV messages for these headers
    forM_ newBlocks $ \n -> do
        broadcastMap <- spvGets peerBroadcastBlocks
        newList <- forM (M.toList broadcastMap) $ \(r, bs) -> do
            when (nodeBlockHash n `elem` bs) $
                increasePeerHeight r $ nodeHeaderHeight n
            return (r, filter (/= nodeBlockHash n) bs)
        spvModify $ \s -> s{ peerBroadcastBlocks = M.fromList newList }

    -- Continue syncing from this node only if it made some progress.
    -- Otherwise, another peer is probably faster/ahead already.
    when (workAfter > workBefore) $ do
        let newHeight = nodeHeaderHeight $ last newBlocks
        increasePeerHeight remote newHeight

        -- Update the sync peer 
        isSynced <- blockHeadersSynced
        spvModify $ \s -> 
            s{ spvSyncPeer = if isSynced then Nothing else Just remote }

        $(logInfo) $ T.pack $ unwords
            [ "New best header height:"
            , show newHeight
            ]

        -- Requesting more headers
        sendGetHeaders remote False 0x00

    -- Request block downloads for all peers that are currently idling
    remotePeers <- getPeerKeys
    forM_ remotePeers downloadBlocks

processInv :: SPVNode a s t => RemoteHost -> Inv -> SPVHandle a t ()
processInv remote (Inv vs) = do

    -- Process transactions
    unless (null txlist) $ do
        $(logInfo) $ T.pack $ unwords
            [ "Got tx inv"
            , "["
            , unwords $ map encodeTxHashLE txlist
            , "]"
            , "(", show remote, ")" 
            ]
        downloadTxs remote txlist

    -- Process blocks
    unless (null blocklist) $ do
        $(logInfo) $ T.pack $ unwords
            [ "Got block inv"
            , "["
            , unwords $ map encodeBlockHashLE blocklist
            , "]"
            , "(", show remote, ")" 
            ]

        -- Partition blocks that we know and don't know
        let f (a,b) h = existsBlockHeaderNode h >>= \exists -> if exists
                then getBlockHeaderNode h >>= \r -> return (r:a,b)
                else return (a,h:b)

        (have, notHave) <- runHeaderChain $ foldM f ([],[]) blocklist

        -- Update peer height
        let maxHeight = maximum $ 0 : map nodeHeaderHeight have
        increasePeerHeight remote maxHeight

        -- Update broadcasted block list
        addBroadcastBlocks remote notHave

        -- Request headers for blocks we don't have. 
        -- TODO: Filter duplicate requests
        forM_ notHave $ \b -> sendGetHeaders remote True b
  where
    txlist = map (fromIntegral . invHash) $ 
        filter ((== InvTx) . invType) vs
    blocklist = map (fromIntegral . invHash) $ 
        filter ((== InvBlock) . invType) vs

-- These are solo transactions not linked to a merkle block (yet)
processTx :: SPVNode a s t => RemoteHost -> Tx -> SPVHandle a t ()
processTx _ tx = do
    -- Only send to wallet if we are in sync
    synced <- merkleBlocksSynced
    if synced 
        then do
            $(logInfo) $ T.pack $ unwords 
                [ "Got solo tx"
                , encodeTxHashLE txhash 
                , "Sending to the wallet"
                ]
            spvImportTxs [tx]
        else do
            $(logInfo) $ T.pack $ unwords 
                [ "Got solo tx"
                , encodeTxHashLE txhash 
                , "We are not synced. Buffering it."
                ]
            spvModify $ \s -> s{ soloTxs = nub $ tx : soloTxs s } 

    -- Remove the inflight transaction from all remote inflight lists
    txMap <- spvGets peerInflightTxs
    let newMap = M.map (filter ((/= txhash) . fst)) txMap
    spvModify $ \s -> s{ peerInflightTxs = newMap }

    -- Trigger merkle block downloads
    importMerkleBlocks 
  where
    txhash = txHash tx

spvPeerMerkleBlock :: SPVNode a s t 
                   => RemoteHost -> DecodedMerkleBlock -> SPVHandle a t ()
spvPeerMerkleBlock remote dmb = do
    -- Ignore unsolicited merkle blocks
    existsNode <- runHeaderChain $ existsBlockHeaderNode bid
    when existsNode $ do
        node <- runHeaderChain $ getBlockHeaderNode bid
        -- Remove merkle blocks from the inflight list
        removeInflightMerkle remote bid

        -- Check if the merkle block is valid
        let isValid = decodedRoot dmb == (merkleRoot $ nodeHeader node)
        unless isValid $ $(logWarn) $ T.pack $ unwords
            [ "Received invalid merkle block: "
            , encodeBlockHashLE bid
            , "(", show remote, ")" 
            ]

        -- When a rescan is pending, don't store the merkle blocks
        rescan <- spvGets pendingRescan
        when (isNothing rescan && isValid) $ do
            -- Insert the merkle block into the received list
            addReceivedMerkle (nodeHeaderHeight node) dmb
            -- Import merkle blocks in order
            importMerkleBlocks 
            downloadBlocks remote

        -- Try to launch the rescan if one is pending
        hasMoreInflight <- liftM (M.member remote) $ spvGets peerInflightMerkles
        when (isJust rescan && not hasMoreInflight) $ 
            processRescan $ fromJust rescan
  where
    bid = headerHash $ merkleHeader $ decodedMerkle dmb

-- This function will make sure that the merkle blocks are imported in-order
-- as they may be received out-of-order from the network (concurrent download)
importMerkleBlocks :: SPVNode a s t => SPVHandle a t ()
importMerkleBlocks = do
    -- Find all inflight transactions
    inflightTxs <- liftM (concat . M.elems) $ spvGets peerInflightTxs
    -- If we are pending a rescan, do not import anything
    rescan  <- spvGets pendingRescan
    -- We stall merkle block imports when transactions are inflight. This
    -- is to prevent this race condition where tx1 would miss it's
    -- confirmation:
    -- INV tx1 -> GetData tx1 -> MerkleBlock (all tx except tx1) -> Tx1
    when (null inflightTxs && isNothing rescan) $ do
        toImport  <- liftM (concat . M.elems) $ spvGets receivedMerkle
        wasImported <- liftM or $ forM toImport importMerkleBlock
        when wasImported $ do
            -- Check if we are in sync
            synced <- merkleBlocksSynced
            when synced $ do
                -- If we are synced, send solo transactions to the wallet
                solo <- spvGets soloTxs
                spvModify $ \s -> s{ soloTxs = [] }
                spvImportTxs solo

                -- Log current height
                bestBlock <- runHeaderChain getBestBlock
                $(logInfo) $ T.pack $ unwords
                    [ "Merkle blocks are in sync at height:"
                    , show $ nodeHeaderHeight bestBlock
                    ]

            -- Try to import more merkle blocks if some were imported this round
            importMerkleBlocks

-- Import a single merkle block if its parent has already been imported
importMerkleBlock :: SPVNode a s t => DecodedMerkleBlock -> SPVHandle a t Bool
importMerkleBlock dmb = runHeaderChain (connectBlock bid) >>= \aM -> case aM of
    Just action -> do
        -- If solo transactions belong to this merkle block, we have
        -- to import them and remove them from the solo list.
        solo <- spvGets soloTxs
        let isInMerkle x        = txHash x `elem` expectedTxs dmb
            (soloAdd, soloKeep) = partition isInMerkle solo
            txsToImport         = nub $ merkleTxs dmb ++ soloAdd
        spvModify $ \s -> s{ soloTxs = soloKeep }

        -- Import transactions and merkle block into the wallet
        unless (null txsToImport) $ spvImportTxs txsToImport
        spvImportMerkleBlock action $ expectedTxs dmb

        -- Remove the merkle block from the received merkle list
        removeReceivedMerkle (nodeHeaderHeight $ getActionNode action) dmb

        -- Some logging
        case action of
            BestBlock b      -> logBestBlock b $ length txsToImport
            BlockReorg _ o n -> logReorg o n $ length txsToImport
            SideBlock b _    -> logSideblock b $ length txsToImport
            OldBlock b _     -> logOldBlock b

        return True
    Nothing -> return False
  where
    bid = headerHash $ merkleHeader $ decodedMerkle dmb
    logBestBlock :: SPVNode a s t => BlockHeaderNode -> Int -> SPVHandle a t ()
    logBestBlock b c = $(logInfo) $ T.pack $ unwords
        [ "Best block at height:"
        , show $ nodeHeaderHeight b, ":"
        , encodeBlockHashLE $ nodeBlockHash b
        , "( Sent", show c, "transactions to the wallet )"
        ]
    logSideblock :: SPVNode a s t => BlockHeaderNode -> Int -> SPVHandle a t ()
    logSideblock b c = $(logInfo) $ T.pack $ unwords
        [ "Side block at height"
        , show $ nodeHeaderHeight b, ":"
        , encodeBlockHashLE $ nodeBlockHash b
        , "( Sent", show c, "transactions to the wallet )"
        ]
    logReorg o n c = $(logInfo) $ T.pack $ unwords
        [ "Block reorg. Orphaned blocks:"
        , "[", unwords $ 
            map (encodeBlockHashLE . nodeBlockHash) o ,"]"
        , "New blocks:"
        , "[", unwords $ 
            map (encodeBlockHashLE . nodeBlockHash) n ,"]"
        , "New height:"
        , show $ nodeHeaderHeight $ last n
        , "( Sent", show c, "transactions to the wallet )"
        ]
    logOldBlock :: SPVNode a s t => BlockHeaderNode -> SPVHandle a t ()
    logOldBlock b = $(logError) $ T.pack $ unwords
        [ "Got duplicate OldBlock:"
        , encodeBlockHashLE $ nodeBlockHash b
        ]

{- Wallet Requests -}

processBloomFilter :: SPVNode a s t => BloomFilter -> SPVHandle a t ()
processBloomFilter bloom = do
    prevBloom <- spvGets spvBloom
    -- Load the new bloom filter if it is not empty
    when (prevBloom /= Just bloom && (not $ isBloomEmpty bloom)) $ do
        $(logInfo) "Loading new bloom filter"
        spvModify $ \s -> s{ spvBloom = Just bloom }

        remotePeers <- getPeerKeys
        forM_ remotePeers $ \remote -> do
            -- Set the new bloom filter on all peer connections
            sendMessage remote $ MFilterLoad $ FilterLoad bloom
            -- Trigger merkle block download for all peers. Merkle block
            -- downloads are paused if no bloom filter is loaded.
            downloadBlocks remote

publishTx :: SPVNode a s t => Tx -> SPVHandle a t ()
publishTx tx = do
    $(logInfo) $ T.pack $ unwords
        [ "Broadcasting transaction to the network:"
        , encodeTxHashLE $ txHash tx
        ]

    peers <- getPeers
    -- TODO: Should we send the transaction through an INV message first?
    forM_ peers $ \(remote, _) -> sendMessage remote $ MTx tx

    -- If no peers are connected, we save the transaction and send it later.
    let txSent = or $ map (peerCompleteHandshake . snd) peers
    unless txSent $ spvModify $ 
        \s -> s{pendingTxBroadcast = tx : pendingTxBroadcast s}

processRescan :: forall a s t. SPVNode a s t => Timestamp -> SPVHandle a t ()
processRescan ts = do
    pending <- liftM (concat . M.elems) $ spvGets peerInflightMerkles
    -- Can't process a rescan while merkle blocks are still inflight
    if (null pending)
        then do
            $(logInfo) $ T.pack $ unwords
                [ "Running rescan from time:"
                , show ts
                ]

            -- Reset the chain and set the new blocks to download
            spvModify $ \s -> s{ blocksToDwn = M.empty }
            addBlocksToDwn =<< runHeaderChain (rescanHeaderChain net ts)

            -- Don't remember old requests
            spvModify $ \s -> s{ pendingRescan  = Nothing
                               , receivedMerkle = M.empty
                               , fastCatchup    = ts
                               }
            -- Trigger downloads
            remotePeers <- getPeerKeys
            forM_ remotePeers downloadBlocks
        else do
            $(logInfo) $ T.pack $ unwords
                [ "Rescan: waiting for pending merkle blocks to download" ]
            spvModify $ \s -> s{ pendingRescan = Just ts }
  where
    net = undefined :: a

heartbeatMonitor :: SPVNode a s t => SPVHandle a t ()
heartbeatMonitor = do
    $(logDebug) "Monitoring heartbeat"

    remotePeers <- getPeerKeys
    now <- round <$> liftIO getPOSIXTime
    let isStalled t = t + 120 < now -- Stalled for over 2 minutes

    -- Check stalled merkle blocks
    merkleMap <- spvGets peerInflightMerkles
    -- M.Map RemoteHost ([(BlockHash, Timestamp)],[BlockHash, Timestamp])
    let stalledMerkleMap = M.map (partition (isStalled . snd)) merkleMap
        stalledMerkles   = map fst $ concat $ 
                             M.elems $ M.map fst stalledMerkleMap
        badMerklePeers   = M.keys $ M.filter (not . null) $ 
                             M.map fst stalledMerkleMap

    unless (null stalledMerkles) $ do
        $(logWarn) $ T.pack $ unwords
            [ "Resubmitting stalled merkle blocks:"
            , "["
            , unwords $ map (encodeBlockHashLE . snd) stalledMerkles
            , "]"
            ]
        -- Save the new inflight merkle map
        spvModify $ \s -> 
            s{ peerInflightMerkles = M.map snd stalledMerkleMap }
        -- Add stalled merkle blocks to the downloade queue
        addBlocksToDwn stalledMerkles
        -- Reissue merkle block downloads with bad peers at the end
        let reorderedPeers = (remotePeers \\ badMerklePeers) ++ badMerklePeers
        forM_ reorderedPeers downloadBlocks

    -- Check stalled transactions
    txMap <- spvGets peerInflightTxs
    -- M.Map RemoteHost ([(TxHash, Timestamp)], [(TxHash, Timestamp)])
    let stalledTxMap = M.map (partition (isStalled . snd)) txMap
        stalledTxs   = M.filter (not . null) $ M.map fst stalledTxMap

    -- Resubmit transaction download for each peer individually
    forM_ (M.toList stalledTxs) $ \(remote, xs) -> do
        let txsToDwn = map fst xs
        $(logWarn) $ T.pack $ unwords
            [ "Resubmitting stalled transactions:"
            , "["
            , unwords $ map encodeTxHashLE txsToDwn
            , "]"
            ]
        downloadTxs remote txsToDwn

-- Add transaction hashes to the inflight map and send a GetData message
downloadTxs :: SPVNode a s t => RemoteHost -> [TxHash] -> SPVHandle a t ()
downloadTxs remote hs 
    | null hs = return ()
    | otherwise = do
        -- Get current time
        now <- round <$> liftIO getPOSIXTime
        inflightMap <- spvGets peerInflightTxs
        -- Remove existing inflight values for the peer
        let f = not . (`elem` hs) . fst
            filteredMap = M.adjust (filter f) remote inflightMap
        -- Add transactions to the inflight map
            newMap = M.singleton remote $ map (\h -> (h,now)) hs
            newInflightMap = M.unionWith (++) filteredMap newMap
        spvModify $ \s -> s{ peerInflightTxs = newInflightMap }
        -- Send GetData message for those transactions
        let vs = map (InvVector InvTx . fromIntegral) hs
        sendMessage remote $ MGetData $ GetData vs

{- Utilities -}

-- Send out a GetHeaders request for a given peer
sendGetHeaders :: forall a s t. SPVNode a s t 
               => RemoteHost -> Bool -> BlockHash -> SPVHandle a t ()
sendGetHeaders remote full hstop = do
    handshake <- liftM peerCompleteHandshake $ getPeerData remote
    -- Only peers that have finished the connection handshake
    when handshake $ do
        loc <- runHeaderChain $ if full then blockLocator net else do
            h <- getBestBlockHeader
            return [nodeBlockHash h]
        $(logInfo) $ T.pack $ unwords 
            [ "Requesting more BlockHeaders"
            , "["
            , if full 
                then "BlockLocator = Full" 
                else "BlockLocator = Best header only"
            , "]"
            , "(", show remote, ")" 
            ]
        sendMessage remote $ MGetHeaders $ GetHeaders 0x01 loc hstop
  where
    net = undefined :: a

-- Look at the block download queue and request a peer to download more blocks
-- if the peer is connected, idling and meets the block height requirements.
downloadBlocks :: SPVNode a s t => RemoteHost -> SPVHandle a t ()
downloadBlocks remote = canDownloadBlocks remote >>= \dwn -> when dwn $ do
    height <- liftM peerHeight $ getPeerData remote
    dwnMap <- spvGets blocksToDwn

    -- Find blocks that this peer can download
    let xs = concat $ map (\(k,vs) -> map (\v -> (k,v)) vs) $ M.toAscList dwnMap
        (ys, rest) = splitAt 500 xs
        (toDwn, highRest) = span ((<= height) . fst) ys
        restToList = map (\(a,b) -> (a,[b])) $ rest ++ highRest
        restMap = M.fromListWith (++) restToList

    unless (null toDwn) $ do
        $(logInfo) $ T.pack $ unwords 
            [ "Requesting more merkle block(s)"
            , "["
            , if length toDwn == 1
                then encodeBlockHashLE $ snd $ head toDwn
                else unwords [show $ length toDwn, "block(s)"]
            , "]"
            , "(", show remote, ")" 
            ]

        -- Store the new list of blocks to download
        spvModify $ \s -> s{ blocksToDwn = restMap }
        -- Store the new blocks to download as inflght merkle blocks
        addInflightMerkles remote toDwn
        -- Send GetData message to receive the merkle blocks
        sendMerkleGetData remote $ map snd toDwn

-- Only download blocks from peers that have completed the handshake
-- and are idling. Do not allow downloads if a rescan is pending or
-- if no bloom filter was provided yet from the wallet.
canDownloadBlocks :: SPVNode a s t => RemoteHost -> SPVHandle a t Bool
canDownloadBlocks remote = do
    peerData   <- getPeerData remote
    reqM       <- liftM (M.lookup remote) $ spvGets peerInflightMerkles
    bloom      <- spvGets spvBloom
    syncPeer   <- spvGets spvSyncPeer
    rescan     <- spvGets pendingRescan
    return $ (syncPeer /= Just remote)
          && (isJust bloom)
          && (peerCompleteHandshake peerData)
          && (isNothing reqM || reqM == Just [])
          && (isNothing rescan)

sendMerkleGetData :: SPVNode a s t
                  => RemoteHost -> [BlockHash] -> SPVHandle a t ()
sendMerkleGetData remote hs = do
    sendMessage remote $ MGetData $ GetData $ 
        map ((InvVector InvMerkleBlock) . fromIntegral) hs
    -- Send a ping to have a recognizable end message for the last
    -- merkle block download
    -- TODO: Compute a random nonce for the ping
    sendMessage remote $ MPing $ Ping 0

-- Header height = network height
blockHeadersSynced :: SPVNode a s t => SPVHandle a t Bool
blockHeadersSynced = do
    networkHeight <- getBestPeerHeight
    headerHeight <- runHeaderChain bestBlockHeaderHeight
    return $ headerHeight >= networkHeight

-- Merkle block height = network height
merkleBlocksSynced :: SPVNode a s t => SPVHandle a t Bool
merkleBlocksSynced = do
    networkHeight <- getBestPeerHeight
    bestBlock <- runHeaderChain getBestBlock
    return $ (nodeHeaderHeight bestBlock) >= networkHeight

-- Log a message if we are synced up with this peer
logPeerSynced :: SPVNode a s t => RemoteHost -> Version -> SPVHandle a t ()
logPeerSynced remote ver = do
    bestBlock <- runHeaderChain getBestBlock
    when (nodeHeaderHeight bestBlock >= startHeight ver) $
        $(logInfo) $ T.pack $ unwords
            [ "Merkle blocks are in sync with the peer. Peer height:"
            , show $ startHeight ver 
            , "Our height:"
            , show $ nodeHeaderHeight bestBlock
            , "(", show remote, ")" 
            ]

addBroadcastBlocks :: SPVNode a s t
                   => RemoteHost -> [BlockHash] -> SPVHandle a t ()
addBroadcastBlocks remote hs = do
    prevMap <- spvGets peerBroadcastBlocks
    spvModify $ \s -> s{ peerBroadcastBlocks = M.unionWith (++) prevMap sMap }
  where
    sMap = M.singleton remote hs

addBlocksToDwn :: SPVNode a s t 
               => [(BlockHeight, BlockHash)] -> SPVHandle a t ()
addBlocksToDwn hs = do
    dwnMap <- spvGets blocksToDwn
    spvModify $ \s -> s{ blocksToDwn = M.unionWith (++) dwnMap newMap }
  where
    newMap = M.fromListWith (++) $ map (\(a,b) -> (a,[b])) hs

addReceivedMerkle :: SPVNode a s t 
                  => BlockHeight -> DecodedMerkleBlock -> SPVHandle a t ()
addReceivedMerkle h dmb = do
    receivedMap <- spvGets receivedMerkle
    let newMap = M.unionWith (++) receivedMap $ M.singleton h [dmb]
    spvModify $ \s -> s{ receivedMerkle = newMap }

removeReceivedMerkle :: SPVNode a s t 
                     => BlockHeight -> DecodedMerkleBlock -> SPVHandle a t ()
removeReceivedMerkle h dmb = do
    receivedMap <- spvGets receivedMerkle
    let f xs   = g $ delete dmb xs
        g res  = if null res then Nothing else Just res
        newMap = M.update f h receivedMap
    spvModify $ \s -> s{ receivedMerkle = newMap }

addInflightMerkles :: SPVNode a s t 
                   => RemoteHost
                   -> [(BlockHeight, BlockHash)]
                   -> SPVHandle a t ()
addInflightMerkles remote vs = do
    now <- round <$> liftIO getPOSIXTime
    merkleMap <- spvGets peerInflightMerkles
    let newList = map (\v -> (v, now)) vs
        newMap  = M.unionWith (++) merkleMap $ M.singleton remote newList
    spvModify $ \s -> s{ peerInflightMerkles = newMap }

removeInflightMerkle :: SPVNode a s t 
                     => RemoteHost -> BlockHash -> SPVHandle a t ()
removeInflightMerkle remote bid = do
    merkleMap <- spvGets peerInflightMerkles
    let newMap = M.update f remote merkleMap
    spvModify $ \s -> s{ peerInflightMerkles = newMap }
  where
    f xs  = g $ filter ((/= bid) . snd . fst) xs
    g res = if null res then Nothing else Just res

spvGets :: SPVNode a s t => (SPVSession -> b) -> SPVHandle a t b
spvGets f = f <$> S.gets spvSession

spvModify :: SPVNode a s t => (SPVSession -> SPVSession) -> SPVHandle a t ()
spvModify f = S.modify $ \s -> s{ spvSession = f $ spvSession s }

