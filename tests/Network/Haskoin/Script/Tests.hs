module Network.Haskoin.Script.Tests (tests) where

import Test.QuickCheck.Property (Property, (==>))
import Test.QuickCheck ( Positive(..) )
import Test.Framework (Test, testGroup)
import Test.Framework.Providers.QuickCheck2 (testProperty)

import Control.Applicative ((<$>))

import Data.Bits (setBit, testBit)
import Data.Binary (Binary, Word8)
import qualified Data.ByteString as BS 
    ( singleton
    , length
    , tail
    , head
    , pack
    , last
    , reverse
    )

import Network.Haskoin.Protocol.Arbitrary ()
import Network.Haskoin.Script.Arbitrary (ScriptOpInt(..))

import Network.Haskoin.Script
import Network.Haskoin.Script.Exec
import Network.Haskoin.Crypto
import Network.Haskoin.Protocol
import Network.Haskoin.Util

tests :: [Test]
tests = 
    [ testGroup "Script types"
        [ testProperty "ScriptOp" (metaGetPut :: ScriptOp -> Bool)
        , testProperty "Script" (metaGetPut :: Script -> Bool)
        ]
    , testGroup "Script Parser"
        [ testProperty "decode . encode OP_1 .. OP_16" testScriptOpInt
        , testProperty "decode . encode ScriptOutput" testScriptOutput
        , testProperty "decode . encode ScriptInput" testScriptInput
        , testProperty "decode . encode ScriptHashInput" testScriptHashInput
        , testProperty "sorting MultiSig scripts" testSortMulSig
        ]
    , testGroup "Script SigHash"
        [ testProperty "canonical signatures" testCanonicalSig
        , testProperty "decode . encode SigHash" binSigHash
        , testProperty "decode SigHash from Word8" binSigHashByte
        , testProperty "encodeSigHash32 is 4 bytes long" testEncodeSH32
        , testProperty "decode . encode TxSignature" binTxSig
        , testProperty "decodeCanonical . encode TxSignature" binTxSigCanonical
        , testProperty "Testing txSigHash with SigSingle" testSigHashOne
        ]
    , testGroup "Stack Value Conversions"
       [ testProperty "One way Inverse" testOneWayInverse
       , testProperty "Positive MSB" testPositiveMSB
       , testProperty "Negative MSB" testNegativeMSB
       , testProperty "Simple Positive Inverse" testSimplePositiveInverse
       ]
    ]

metaGetPut :: (Binary a, Eq a) => a -> Bool
metaGetPut x = (decode' . encode') x == x

{- Script Parser -}

testScriptOpInt :: ScriptOpInt -> Bool
testScriptOpInt (ScriptOpInt i) = (intToScriptOp <$> scriptOpToInt i) == Right i

testScriptOutput :: ScriptOutput -> Bool
testScriptOutput so = (decodeOutput $ encodeOutput so) == Right so

testScriptInput :: ScriptInput -> Bool
testScriptInput si = (decodeInput $ encodeInput si) == Right si

testScriptHashInput :: ScriptHashInput -> Bool
testScriptHashInput sh = (decodeScriptHash $ encodeScriptHash sh) == Right sh

testSortMulSig :: ScriptOutput -> Bool
testSortMulSig out = case out of
    (PayMulSig _ _) -> check $ sortMulSig out
    _ -> True
    where check (PayMulSig ps _) 
              | length ps <= 1 = True
              | otherwise = snd $ foldl f (head ps,True) $ tail ps
          check _ = False
          f (a,t) b | t && encode' a <= encode' b = (b,True)
                    | otherwise   = (b,False)
        
{- Script SigHash -}

testCanonicalSig :: TxSignature -> Bool
testCanonicalSig ts@(TxSignature _ sh) 
    | isSigUnknown sh = isLeft $ decodeCanonicalSig bs
    | otherwise       = isRight (decodeCanonicalSig bs) && 
                        isCanonicalHalfOrder (txSignature ts)
    where bs = encodeSig ts

binSigHash :: SigHash -> Bool
binSigHash sh = (decode' $ encode' sh) == sh

binSigHashByte :: Word8 -> Bool
binSigHashByte w
    | w == 0x01 = res == SigAll False
    | w == 0x02 = res == SigNone False
    | w == 0x03 = res == SigSingle False
    | w == 0x81 = res == SigAll True
    | w == 0x82 = res == SigNone True
    | w == 0x83 = res == SigSingle True
    | testBit w 7 = res == SigUnknown True w
    | otherwise = res == SigUnknown False w
    where res = decode' $ BS.singleton w

testEncodeSH32 :: SigHash -> Bool
testEncodeSH32 sh = BS.length bs == 4 && BS.head bs == w && BS.tail bs == zs
    where bs = encodeSigHash32 sh
          w  = BS.head $ encode' sh
          zs = BS.pack [0,0,0]

binTxSig :: TxSignature -> Bool
binTxSig ts = (fromRight $ decodeSig $ encodeSig ts) == ts

binTxSigCanonical :: TxSignature -> Bool
binTxSigCanonical ts@(TxSignature _ sh) 
    | isSigUnknown sh = isLeft $ decodeCanonicalSig $ encodeSig ts
    | otherwise = (fromRight $ decodeCanonicalSig $ encodeSig ts) == ts

testSigHashOne :: Tx -> Script -> Bool -> Property
testSigHashOne tx s acp = not (null $ txIn tx) ==> 
    if length (txIn tx) > length (txOut tx) 
        then res == (setBit 0 248)
        else res /= (setBit 0 248)
    where res = txSigHash tx s (length (txIn tx) - 1) (SigSingle acp)

testOneWayInverse :: Integer -> Bool
testOneWayInverse x = ( fromStackVal . toStackVal $ x ) == x

testPositiveMSB :: Positive Integer -> Bool
testPositiveMSB ( Positive x ) = not $ ( flip testBit ) 7 $ BS.last $ toStackVal x

testNegativeMSB :: Positive Integer -> Bool
testNegativeMSB ( Positive x ) = ( flip testBit ) 7 $ BS.last $ toStackVal $ negate x

testSimplePositiveInverse :: Positive Integer -> Bool
testSimplePositiveInverse ( Positive x ) = ( bsToInteger . BS.reverse . toStackVal $ x ) == x
