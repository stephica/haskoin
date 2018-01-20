{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Script.SigHash
( SigHashType(..)
, SigHash(..)
, encodeSigHashForkId
, sigHashToWord8
, word8ToSigHash
, isSigAll
, isSigNone
, isSigSingle
, isSigUnknown
, txSigHash
, TxSignature(..)
, encodeSig
, decodeSig
, decodeCanonicalSig
) where

import           Control.DeepSeq                   (NFData, rnf)
import           Control.Monad                     (liftM2, mzero, (<=<))
import           Data.Aeson                        (FromJSON, ToJSON,
                                                    Value (String), parseJSON,
                                                    toJSON, withText)
import           Data.Bits
import           Data.ByteString                   (ByteString)
import qualified Data.ByteString                   as BS
import           Data.Maybe                        (fromMaybe)
import           Data.Serialize
import           Data.Serialize.Put                (runPut)
import           Data.String.Conversions           (cs)
import           Data.Word
import           Network.Haskoin.Constants
import           Network.Haskoin.Crypto.ECDSA
import           Network.Haskoin.Crypto.Hash
import           Network.Haskoin.Script.Types
import           Network.Haskoin.Transaction.Types
import           Network.Haskoin.Util

data SigHashType
    -- | Sign all of the outputs of a transaction (This is the default value).
    -- Changing any of the outputs of the transaction will invalidate the
    -- signature.
    = SigAll
    -- | Sign none of the outputs of a transaction. This allows anyone to
    -- change any of the outputs of the transaction.
    | SigNone
    -- | Sign only the output corresponding the the current transaction input.
    -- You care about your own output in the transaction but you don't
    -- care about any of the other outputs.
    | SigSingle
    -- | Unrecognized sighash types will decode to SigUnknown.
    | SigUnknown { getSigCode :: !Word8 }
    deriving (Eq, Show)

-- | Data type representing the different ways a transaction can be signed.
-- When producing a signature, a hash of the transaction is used as the message
-- to be signed. The 'SigHash' parameter controls which parts of the
-- transaction are used or ignored to produce the transaction hash. The idea is
-- that if some part of a transaction is not used to produce the transaction
-- hash, then you can change that part of the transaction after producing a
-- signature without invalidating that signature.
--
-- If the anyoneCanPay flag is True, then only the current input is signed.
-- Otherwise, all of the inputs of a transaction are signed. The default value
-- for anyoneCanPay is False.
data SigHash = SigHash
    { sigHashType         :: !SigHashType
    , sigHashAnyoneCanPay :: !Bool
    , sigHashForkId       :: !Bool
    } deriving (Eq, Show)

instance NFData SigHashType where
    rnf (SigUnknown c) = rnf c
    rnf _              = ()

instance NFData SigHash where
    rnf (SigHash t a f) = rnf t `seq` rnf a `seq` rnf f

instance ToJSON SigHash where
    toJSON = String . cs . encodeHex . encode

instance FromJSON SigHash where
    parseJSON = withText "sighash" $
        maybe mzero return . (eitherToMaybe . decode <=< decodeHex) . cs

-- | Returns True if the 'SigHash' has the value SigAll.
isSigAll :: SigHash -> Bool
isSigAll sh =
    case sigHashType sh of
        SigAll -> True
        _      -> False

-- | Returns True if the 'SigHash' has the value SigNone.
isSigNone :: SigHash -> Bool
isSigNone sh =
    case sigHashType sh of
        SigNone -> True
        _       -> False

-- | Returns True if the 'SigHash' has the value SigSingle.
isSigSingle :: SigHash -> Bool
isSigSingle sh =
    case sigHashType sh of
        SigSingle -> True
        _         -> False

-- | Returns True if the 'SigHash' has the value SigUnknown.
isSigUnknown :: SigHash -> Bool
isSigUnknown sh =
    case sigHashType sh of
        SigUnknown _ -> True
        _            -> False

instance Serialize SigHash where
    get = word8ToSigHash <$> getWord8
    put = putWord8 . sigHashToWord8

sigHashToWord8 :: SigHash -> Word8
sigHashToWord8 sh =
    f1 . f2 $ w
  where
    w = case sigHashType sh of
            SigAll       -> 1
            SigNone      -> 2
            SigSingle    -> 3
            SigUnknown n -> n
    f1 | sigHashForkId sh = (`setBit` 6)
       | otherwise = id
    f2 | sigHashAnyoneCanPay sh = (`setBit` 7)
       | otherwise = id

word8ToSigHash :: Word8 -> SigHash
word8ToSigHash w =
    SigHash
    { sigHashType =
          case (`clearBit` 7) . (`clearBit` 6) $ w of
              1 -> SigAll
              2 -> SigNone
              3 -> SigSingle
              n -> SigUnknown n
    , sigHashAnyoneCanPay = w `testBit` 7
    , sigHashForkId = w `testBit` 6
    }

-- | Encodes a 'SigHash' to a 32 bit-long bytestring.
encodeSigHashForkId :: SigHash -> ByteString
encodeSigHashForkId sh =
    runPut $ putWord32le w
  where
    w = sigHashForkValue `shiftL` 8 .|. fromIntegral (sigHashToWord8 sh)

-- | Computes the hash that will be used for signing a transaction.
txSigHash :: Tx      -- ^ Transaction to sign.
          -> Script  -- ^ Output script that is being spent.
          -> Int     -- ^ Index of the input that is being signed.
          -> SigHash -- ^ What parts of the transaction should be signed.
          -> Hash256 -- ^ Result hash to be signed.
txSigHash tx out i sh = do
    let newIn = buildInputs (txIn tx) out i sh
    -- When SigSingle and input index > outputs, then sign integer 1
    fromMaybe one $ do
        newOut <- buildOutputs (txOut tx) i sh
        let newTx = createTx (txVersion tx) newIn newOut (txLockTime tx)
        return $
            doubleHash256 $
            encode newTx `BS.append` encodeSigHashForkId sh
  where
    one = "0100000000000000000000000000000000000000000000000000000000000000"

-- Builds transaction inputs for computing SigHashes
buildInputs :: [TxIn] -> Script -> Int -> SigHash -> [TxIn]
buildInputs txins out i sh
    | sigHashAnyoneCanPay sh =
        [ (txins !! i) { scriptInput = encode out } ]
    | isSigAll sh || isSigUnknown sh = single
    | otherwise = zipWith noSeq single [0 ..]
  where
    empty = map (\ti -> ti { scriptInput = BS.empty }) txins
    single =
        updateIndex i empty $ \ti -> ti { scriptInput = encode out }
    noSeq ti j =
        if i == j
        then ti
        else ti { txInSequence = 0 }

-- Build transaction outputs for computing SigHashes
buildOutputs :: [TxOut] -> Int -> SigHash -> Maybe [TxOut]
buildOutputs txos i sh
    | isSigAll sh || isSigUnknown sh = return txos
    | isSigNone sh = return []
    | i >= length txos = Nothing
    | otherwise = return $ buffer ++ [txos !! i]
  where
    buffer = replicate i $ TxOut maxBound BS.empty

-- | Data type representing a 'Signature' together with a 'SigHash'. The
-- 'SigHash' is serialized as one byte at the end of a regular ECDSA
-- 'Signature'. All signatures in transaction inputs are of type 'TxSignature'.
data TxSignature = TxSignature
    { txSignature        :: !Signature
    , txSignatureSigHash :: !SigHash
    } deriving (Eq, Show)

instance NFData TxSignature where
    rnf (TxSignature s h) = rnf s `seq` rnf h

-- | Serialize a 'TxSignature' to a ByteString.
encodeSig :: TxSignature -> ByteString
encodeSig (TxSignature sig sh) = runPut $ put sig >> put sh

-- | Decode a 'TxSignature' from a ByteString.
decodeSig :: ByteString -> Either String TxSignature
decodeSig bs = do
    let (h, l) = BS.splitAt (BS.length bs - 1) bs
    liftM2 TxSignature (decode h) (decode l)

decodeCanonicalSig :: ByteString -> Either String TxSignature
decodeCanonicalSig bs
    | hashtype < 1 || hashtype > 3 =
        Left "Non-canonical signature: unknown hashtype byte"
    | otherwise =
        case decodeStrictSig $ BS.init bs of
            Just sig ->
                TxSignature sig <$> decode (BS.singleton $ BS.last bs)
            Nothing  ->
                Left "Non-canonical signature: could not parse signature"
  where
    hashtype = clearBit (BS.last bs) 7
