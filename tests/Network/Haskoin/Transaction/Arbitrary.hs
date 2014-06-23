{-|
  Arbitrary instances for transaction package
-}
module Network.Haskoin.Transaction.Arbitrary 
( genPubKeyC
, genMulSigInput
, genRegularInput 
, genAddrOutput
, RegularTx(..)
, MSParam(..)
, PKHashSigTemplate(..)
, MulSigTemplate(..)
) where

import Test.QuickCheck 
    ( Gen
    , Arbitrary
    , arbitrary
    , vectorOf
    , oneof
    , choose
    )

import Control.Monad (liftM)
import Control.Applicative ((<$>),(<*>))

import Data.List (permutations, nubBy)

import Network.Haskoin.Crypto.Arbitrary 
import Network.Haskoin.Protocol.Arbitrary ()
import Network.Haskoin.Script.Arbitrary ()
import Network.Haskoin.Types.Arbitrary ()

import Network.Haskoin.Transaction
import Network.Haskoin.Script
import Network.Haskoin.Protocol
import Network.Haskoin.Types
import Network.Haskoin.Crypto
import Network.Haskoin.Util

-- | Data type for generating arbitrary valid multisignature parameters (m of n)
data MSParam = MSParam Int Int deriving (Eq, Show)

instance Arbitrary MSParam where
    arbitrary = do
        n <- choose (1,16)
        m <- choose (1,n)
        return $ MSParam m n

-- | Data type for generating arbitrary transaction with inputs and outputs
-- consisting only of script hash or pub key hash scripts.
data RegularTx = RegularTx Tx deriving (Eq, Show)

-- | Generate an arbitrary compressed public key.
genPubKeyC :: Gen PubKey
genPubKeyC = derivePubKey <$> genPrvKeyC

-- | Generate an arbitrary script hash input spending a multisignature
-- pay to script hash.
genMulSigInput :: Gen ScriptHashInput
genMulSigInput = do
    (MSParam m n) <- arbitrary
    rdm <- PayMulSig <$> (vectorOf n genPubKeyC) <*> (return m)
    inp <- SpendMulSig <$> (vectorOf m arbitrary) <*> (return m)
    return $ ScriptHashInput inp rdm

-- | Generate an arbitrary transaction input spending a public key hash or
-- script hash output.
genRegularInput :: Gen TxIn
genRegularInput = do
    op <- arbitrary
    sq <- arbitrary
    sc <- oneof [ encodeScriptHashBS <$> genMulSigInput
                , encodeInputBS <$> (SpendPKHash <$> arbitrary <*> genPubKeyC)
                ]
    return $ TxIn op sc sq

-- | Generate an arbitrary output paying to a public key hash or script hash
-- address.
genAddrOutput :: Gen TxOut
genAddrOutput = do
    v  <- arbitrary
    sc <- oneof [ (PayPKHash . pubKeyAddr) <$> arbitrary
                , (PayScriptHash . scriptAddr) <$> arbitrary
                ]
    return $ TxOut v $ encodeOutputBS sc

instance Arbitrary RegularTx where
    arbitrary = do
        x <- choose (1,10)
        y <- choose (1,10)
        liftM RegularTx $ Tx <$> arbitrary 
                             <*> (vectorOf x genRegularInput) 
                             <*> (vectorOf y genAddrOutput) 
                             <*> arbitrary

instance Arbitrary Coin where
    arbitrary = Coin <$> arbitrary <*> arbitrary <*> arbitrary

data PKHashSigTemplate = PKHashSigTemplate Tx [SigInput] [PrvKey]
    deriving (Eq, Show)

data MulSigTemplate = MulSigTemplate Tx [SigInput] [PrvKey]
    deriving (Eq, Show)

-- Generates a private key that can sign a input using the OutPoint and SigInput
genPKHashData :: Gen (OutPoint, SigInput, PrvKey)
genPKHashData = do
    op  <- arbitrary
    prv <- arbitrary
    sh  <- arbitrary
    let pub    = derivePubKey prv
        script = encodeOutput $ PayPKHash $ pubKeyAddr pub
        sigi   = SigInput script op sh
    return (op, sigi, prv)

-- Generates private keys that can sign an input using the OutPoint and SigInput
genMSData :: Gen (OutPoint, SigInput, [PrvKey])
genMSData = do
    (MSParam m n) <- arbitrary
    prv     <- vectorOf n arbitrary
    perm    <- choose (0,n-1)
    op      <- arbitrary
    sh      <- arbitrary
    let pub    = map derivePubKey prv
        rdm    = PayMulSig pub m
        script = encodeOutput $ PayScriptHash $ scriptAddr rdm
        sigi   = SigInputSH script op (encodeOutput rdm) sh
        perPrv = permutations prv !! perm
    return (op, sigi, take m perPrv)

genPayTo :: Gen (String,BTC)
genPayTo = do
    v  <- arbitrary
    sc <- oneof [ PubKeyAddress <$> arbitrary
                , ScriptAddress <$> arbitrary
                ]
    return (addrToBase58 sc, v)

-- Generates data for signing a PKHash transaction
instance Arbitrary PKHashSigTemplate where
    arbitrary = do
        inC   <- choose (0,5)
        outC  <- choose (0,10)
        dat   <- nubBy (\a b -> fst3 a == fst3 b) <$> vectorOf inC genPKHashData
        perm  <- choose (0,max 0 $ length dat - 1)
        payTo <- vectorOf outC genPayTo
        let tx   = fromRight $ buildAddrTx (map fst3 dat) payTo
            perI = permutations (map snd3 dat) !! perm
        return $ PKHashSigTemplate tx perI (map lst3 dat)

-- Generates data for signing a P2SH transactions
instance Arbitrary MulSigTemplate where
    arbitrary = do
        inC   <- choose (0,5)
        outC  <- choose (0,10)
        dat   <- nubBy (\a b -> fst3 a == fst3 b) <$> vectorOf inC genMSData
        perm  <- choose (0,max 0 $ length dat - 1)
        payTo <- vectorOf outC genPayTo
        let tx   = fromRight $ buildAddrTx (map fst3 dat) payTo
            perI = permutations (map snd3 dat) !! perm
        return $ MulSigTemplate tx perI (concat $ map lst3 dat)

