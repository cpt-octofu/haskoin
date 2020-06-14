{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-|
Module      : Haskoin.Address
Copyright   : No rights reserved
License     : UNLICENSE
Maintainer  : jprupp@protonmail.ch
Stability   : experimental
Portability : POSIX

Base58, CashAddr, Bech32 address and WIF private key serialization support.
-}
module Haskoin.Address
    ( -- * Addresses
      Address(..)
    , isPubKeyAddress
    , isScriptAddress
    , isWitnessPubKeyAddress
    , isWitnessScriptAddress
    , addrToText
    , textToAddr
    , addrToJSON
    , addrToEncoding
    , addrFromJSON
    , pubKeyAddr
    , pubKeyWitnessAddr
    , pubKeyCompatWitnessAddr
    , p2pkhAddr
    , p2wpkhAddr
    , p2shAddr
    , p2wshAddr
    , inputAddress
    , outputAddress
    , addressToScript
    , addressToScriptBS
    , addressToOutput
    , payToScriptAddress
    , payToWitnessScriptAddress
    , payToNestedScriptAddress
    , scriptToAddress
    , scriptToAddressBS
      -- ** Private Key Wallet Import Format (WIF)
    , fromWif
    , toWif
    , module Haskoin.Address.Base58
    , module Haskoin.Address.Bech32
    , module Haskoin.Address.CashAddr
    ) where

import           Control.Applicative
import           Control.DeepSeq
import           Control.Monad
import           Data.Aeson               as A
import           Data.Aeson.Encoding      as A
import           Data.Aeson.Types
import           Data.ByteString          (ByteString)
import qualified Data.ByteString          as B
import           Data.Hashable
import           Data.Maybe
import           Data.Serialize           as S
import           Data.Text                (Text)
import           GHC.Generics             (Generic)
import           Haskoin.Address.Base58
import           Haskoin.Address.Bech32
import           Haskoin.Address.CashAddr
import           Haskoin.Constants
import           Haskoin.Crypto
import           Haskoin.Keys.Common
import           Haskoin.Script
import           Haskoin.Util

-- | Address format for Bitcoin and Bitcoin Cash.
data Address
    -- | pay to public key hash (regular)
    = PubKeyAddress
          { getAddrHash160 :: !Hash160
          -- ^ RIPEMD160 hash of public key's SHA256 hash
          }
    -- | pay to script hash
    | ScriptAddress
          { getAddrHash160 :: !Hash160
          -- ^ RIPEMD160 hash of script's SHA256 hash
          }
    -- | pay to witness public key hash
    | WitnessPubKeyAddress
          { getAddrHash160 :: !Hash160
          -- ^ RIPEMD160 hash of public key's SHA256 hash
          }
    -- | pay to witness script hash
    | WitnessScriptAddress
          { getAddrHash256 :: !Hash256
          -- ^ HASH256 hash of script
          }
    deriving (Eq, Ord, Generic, Show, Read, Serialize, Hashable, NFData)

-- | 'Address' pays to a public key hash.
isPubKeyAddress :: Address -> Bool
isPubKeyAddress PubKeyAddress {} = True
isPubKeyAddress _                = False

-- | 'Address' pays to a script hash.
isScriptAddress :: Address -> Bool
isScriptAddress ScriptAddress {} = True
isScriptAddress _                = False

-- | 'Address' pays to a witness public key hash. Only valid for SegWit
-- networks.
isWitnessPubKeyAddress :: Address -> Bool
isWitnessPubKeyAddress WitnessPubKeyAddress {} = True
isWitnessPubKeyAddress _                       = False

isWitnessScriptAddress :: Address -> Bool
isWitnessScriptAddress WitnessScriptAddress {} = True
isWitnessScriptAddress _                       = False

addrToJSON :: Network -> Address -> Value
addrToJSON net a = toJSON (addrToText net a)

addrToEncoding :: Network -> Address -> Encoding
addrToEncoding net = maybe null_ text . addrToText net

-- | JSON parsing for Bitcoin addresses. Works with 'Base58', 'CashAddr' and
-- 'Bech32'.
addrFromJSON :: Network -> Value -> Parser Address
addrFromJSON net =
    withText "address" $ \t ->
        case textToAddr net t of
            Nothing -> fail "could not decode address"
            Just x  -> return x

-- | Convert address to human-readable string. Uses 'Base58', 'Bech32', or
-- 'CashAddr' depending on network.
addrToText :: Network -> Address -> Maybe Text
addrToText net a@PubKeyAddress {getAddrHash160 = h}
    | isNothing (getCashAddrPrefix net) =
        Just . encodeBase58Check . runPut $ base58put net a
    | otherwise = cashAddrEncode net 0 (S.encode h)
addrToText net a@ScriptAddress {getAddrHash160 = h}
    | isNothing (getCashAddrPrefix net) =
        Just . encodeBase58Check . runPut $ base58put net a
    | otherwise =
        cashAddrEncode net 1 (S.encode h)
addrToText net WitnessPubKeyAddress {getAddrHash160 = h} = do
    hrp <- getBech32Prefix net
    segwitEncode hrp 0 (B.unpack (S.encode h))
addrToText net WitnessScriptAddress {getAddrHash256 = h} = do
    hrp <- getBech32Prefix net
    segwitEncode hrp 0 (B.unpack (S.encode h))

-- | Parse 'Base58', 'Bech32' or 'CashAddr' address, depending on network.
textToAddr :: Network -> Text -> Maybe Address
textToAddr net bs =
    cash <|> segwit <|> b58
  where
    b58 = eitherToMaybe . runGet (base58get net) =<< decodeBase58Check bs
    cash =
        cashAddrDecode net bs >>= \(ver, bs') ->
            case ver of
                0 -> do
                    h <- eitherToMaybe (S.decode bs')
                    return $ PubKeyAddress h
                1 -> do
                    h <- eitherToMaybe (S.decode bs')
                    return $ ScriptAddress h
                _ -> Nothing
    segwit = do
        hrp <- getBech32Prefix net
        (ver, bs') <- segwitDecode hrp bs
        guard (ver == 0)
        let bs'' = B.pack bs'
        case B.length bs'' of
            20 -> do
                h <- eitherToMaybe (S.decode bs'')
                return $ WitnessPubKeyAddress h
            32 -> do
                h <- eitherToMaybe (S.decode bs'')
                return $ WitnessScriptAddress h
            _ -> Nothing

base58get :: Network -> Get Address
base58get net = do
    pfx <- getWord8
    addr <- S.get
    f pfx addr
  where
    f x a
        | x == getAddrPrefix net = return $ PubKeyAddress a
        | x == getScriptPrefix net = return $ ScriptAddress a
        | otherwise = fail "Does not recognize address prefix"

base58put :: Network -> Putter Address
base58put net (PubKeyAddress h) = do
        putWord8 (getAddrPrefix net)
        put h
base58put net (ScriptAddress h) = do
        putWord8 (getScriptPrefix net)
        put h
base58put _ _ = error "Cannot serialize this address as Base58"

-- | Obtain a standard pay-to-public-key-hash address from a public key.
pubKeyAddr :: PubKeyI -> Address
pubKeyAddr = PubKeyAddress . addressHash . S.encode

-- | Obtain a standard pay-to-public-key-hash (P2PKH) address from a 'Hash160'.
p2pkhAddr :: Hash160 -> Address
p2pkhAddr = PubKeyAddress

-- | Obtain a SegWit pay-to-witness-public-key-hash (P2WPKH) address from a
-- public key.
pubKeyWitnessAddr :: PubKeyI -> Address
pubKeyWitnessAddr = WitnessPubKeyAddress . addressHash . S.encode

-- | Obtain a backwards-compatible SegWit P2SH-P2WPKH address from a public key.
pubKeyCompatWitnessAddr :: PubKeyI -> Address
pubKeyCompatWitnessAddr =
    p2shAddr .
    addressHash . encodeOutputBS . PayWitnessPKHash . addressHash . S.encode

-- | Obtain a SegWit pay-to-witness-public-key-hash (P2WPKH) address from a
-- 'Hash160'.
p2wpkhAddr :: Hash160 -> Address
p2wpkhAddr = WitnessPubKeyAddress

-- | Obtain a standard pay-to-script-hash (P2SH) address from a 'Hash160'.
p2shAddr :: Hash160 -> Address
p2shAddr = ScriptAddress

-- | Obtain a SegWit pay-to-witness-script-hash (P2WSH) address from a 'Hash256'
p2wshAddr :: Hash256 -> Address
p2wshAddr = WitnessScriptAddress

-- | Compute a standard pay-to-script-hash (P2SH) address for an output script.
payToScriptAddress :: ScriptOutput -> Address
payToScriptAddress = p2shAddr . addressHash . encodeOutputBS

-- | Compute a SegWit pay-to-witness-script-hash (P2WSH) address for an output
-- script.
payToWitnessScriptAddress :: ScriptOutput -> Address
payToWitnessScriptAddress = p2wshAddr . sha256 . encodeOutputBS

-- | Compute a backwards-compatible SegWit P2SH-P2WSH address.
payToNestedScriptAddress :: ScriptOutput -> Address
payToNestedScriptAddress =
    p2shAddr . addressHash . encodeOutputBS . toP2WSH . encodeOutput

-- | Encode an output script from an address. Will fail if using a
-- pay-to-witness address on a non-SegWit network.
addressToOutput :: Address -> ScriptOutput
addressToOutput =
    \case
        (PubKeyAddress h) -> PayPKHash h
        (ScriptAddress h) -> PayScriptHash h
        (WitnessPubKeyAddress h) -> PayWitnessPKHash h
        (WitnessScriptAddress h) -> PayWitnessScriptHash h

-- | Get output script AST for an 'Address'.
addressToScript :: Address -> Script
addressToScript = encodeOutput . addressToOutput

-- | Encode address as output script in 'ByteString' form.
addressToScriptBS :: Address -> ByteString
addressToScriptBS = S.encode . addressToScript

-- | Decode an output script into an 'Address' if it has such representation.
scriptToAddress :: Script -> Either String Address
scriptToAddress =
    maybeToEither "Could not decode address" . outputAddress <=< decodeOutput

-- | Decode a serialized script into an 'Address'.
scriptToAddressBS :: ByteString -> Either String Address
scriptToAddressBS =
    maybeToEither "Could not decode address" . outputAddress <=< decodeOutputBS

-- | Get the 'Address' of a 'ScriptOutput'.
outputAddress :: ScriptOutput -> Maybe Address
outputAddress =
    \case
        (PayPKHash h) -> Just $ PubKeyAddress h
        (PayScriptHash h) -> Just $ ScriptAddress h
        (PayPK k) -> Just $ pubKeyAddr k
        (PayWitnessPKHash h) -> Just $ WitnessPubKeyAddress h
        (PayWitnessScriptHash h) -> Just $ WitnessScriptAddress h
        _ -> Nothing

-- | Infer the 'Address' of a 'ScriptInput'.
inputAddress :: ScriptInput -> Maybe Address
inputAddress =
    \case
        (RegularInput (SpendPKHash _ key)) -> Just $ pubKeyAddr key
        (ScriptHashInput _ rdm) -> Just $ payToScriptAddress rdm
        _ -> Nothing

-- | Decode private key from WIF (wallet import format) string.
fromWif :: Network -> Base58 -> Maybe SecKeyI
fromWif net wif = do
    bs <- decodeBase58Check wif
    -- Check that this is a private key
    guard (B.head bs == getSecretPrefix net)
    case B.length bs of
        -- Uncompressed format
        33 -> wrapSecKey False <$> secKey (B.tail bs)
        -- Compressed format
        34 -> do
            guard $ B.last bs == 0x01
            wrapSecKey True <$> secKey (B.tail $ B.init bs)
        -- Bad length
        _  -> Nothing

-- | Encode private key into a WIF string.
toWif :: Network -> SecKeyI -> Base58
toWif net (SecKeyI k c) =
    encodeBase58Check . B.cons (getSecretPrefix net) $
    if c
        then getSecKey k `B.snoc` 0x01
        else getSecKey k
