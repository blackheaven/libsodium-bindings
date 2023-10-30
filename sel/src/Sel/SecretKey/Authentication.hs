{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- |
--
-- Module: Sel.SecretKey.Authentication
-- Description: Authentication with HMAC-SHA512-256
-- Maintainer: The Haskell Cryptography Group
-- Portability: GHC only
module Sel.SecretKey.Authentication
  ( -- ** Introduction
    -- $introduction

    -- ** Usage
    -- $usage

    -- ** Operations
    authenticate
  , verify

    -- ** Authentication key
  , AuthenticationKey
  , newAuthenticationKey
  , authenticationKeyFromHexByteString
  , unsafeAuthenticationKeyToHexByteString
  , freeAuthenticationKey

    -- ** Authentication tag
  , AuthenticationTag
  , authenticationTagToHexByteString
  , authenticationTagFromHexByteString
  ) where

import Control.Monad (void, when)
import qualified Data.Base16.Types as Base16
import Data.ByteString (StrictByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Internal as BS
import qualified Data.ByteString.Unsafe as BS
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Display (Display, OpaqueInstance (..), ShowInstance (..))
import Data.Word (Word8)
import Foreign (ForeignPtr)
import qualified Foreign
import Foreign.C (CChar, CSize, CUChar, CULLong, throwErrno)
import System.IO.Unsafe (unsafeDupablePerformIO)

import LibSodium.Bindings.CryptoAuth
  ( cryptoAuth
  , cryptoAuthBytes
  , cryptoAuthKeyBytes
  , cryptoAuthKeygen
  , cryptoAuthVerify
  )
import LibSodium.Bindings.SecureMemory
import Sel.Internal

-- $introduction
-- The 'authenticate' function computes an authentication tag for a message and a secret key,
-- and provides a way to verify that a given tag is valid for a given message and a key.
--
-- The function computing the tag deterministic: the same @(message, key)@ tuple will always
-- produce the same output. However, even if the message is public, knowing the key is required
-- in order to be able to compute a valid tag.
-- Therefore, the key should remain confidential. The tag, however, can be public.

-- |
--
-- @since 0.0.1.0
authenticate
  :: StrictByteString
  -- ^ Message to authenticate
  -> AuthenticationKey
  -- ^ Secret key for authentication
  -> IO AuthenticationTag
  -- ^ Cryptographic tag for authentication
authenticate message (AuthenticationKey authenticationKeyForeignPtr) =
  BS.unsafeUseAsCStringLen message $ \(cString, cStringLen) -> do
    authenticationTagForeignPtr <-
      Foreign.mallocForeignPtrBytes
        (fromIntegral cryptoAuthBytes)
    Foreign.withForeignPtr authenticationTagForeignPtr $ \authTagPtr ->
      Foreign.withForeignPtr authenticationKeyForeignPtr $ \authKeyPtr ->
        void $
          cryptoAuth
            authTagPtr
            (Foreign.castPtr @CChar @CUChar cString)
            (fromIntegral @Int @CULLong cStringLen)
            authKeyPtr
    pure $ AuthenticationTag authenticationTagForeignPtr

-- | Verify that the tag is valid for the provided message and secret key.
--
-- @since 0.0.1.0
verify
  :: AuthenticationTag
  -> AuthenticationKey
  -> StrictByteString
  -> Bool
verify (AuthenticationTag tagForeignPtr) (AuthenticationKey keyForeignPtr) message = unsafeDupablePerformIO $
  BS.unsafeUseAsCStringLen message $ \(cString, cStringLen) ->
    Foreign.withForeignPtr tagForeignPtr $ \authTagPtr ->
      Foreign.withForeignPtr keyForeignPtr $ \authKeyPtr -> do
        result <-
          cryptoAuthVerify
            authTagPtr
            (Foreign.castPtr @CChar @CUChar cString)
            (fromIntegral @Int @CULLong cStringLen)
            authKeyPtr
        pure $ result == 0

-- | A secret authentication key of size 'cryptoAuthKeyBytes'.
--
-- @since 0.0.1.0
newtype AuthenticationKey = AuthenticationKey (ForeignPtr CUChar)
  deriving
    ( Display
      -- ^ @since 0.0.1.0
      -- > display authenticatonKey == "[REDACTED]"
    )
    via (OpaqueInstance "[REDACTED]" AuthenticationKey)

-- |
--
-- @since 0.0.1.0
instance Eq AuthenticationKey where
  (AuthenticationKey hk1) == (AuthenticationKey hk2) =
    unsafeDupablePerformIO $
      foreignPtrEq hk1 hk2 cryptoAuthKeyBytes

-- |
--
-- @since 0.0.1.0
instance Ord AuthenticationKey where
  compare (AuthenticationKey hk1) (AuthenticationKey hk2) =
    unsafeDupablePerformIO $
      foreignPtrOrd hk1 hk2 cryptoAuthKeyBytes

-- | > show authenticationKey == "[REDACTED]"
--
-- @since 0.0.1.0
instance Show AuthenticationKey where
  show _ = "[REDACTED]"

-- | Generate a new random secret key.
--
-- @since 0.0.1.0
newAuthenticationKey :: IO AuthenticationKey
newAuthenticationKey = newAuthenticationKeyWith cryptoAuthKeygen

-- | Prepare memory for a 'AuthenticationKey' and use the provided action to fill it.
--
-- Memory is allocated with 'LibSodium.Bindings.SecureMemory.sodiumMalloc'
-- (see the note attached there).
-- Finalizer is run when the key is goes out of scope, but 'freeAuthenticationKey'
-- can be used to release early.
--
-- @since 0.0.1.0
newAuthenticationKeyWith :: (Foreign.Ptr CUChar -> IO ()) -> IO AuthenticationKey
newAuthenticationKeyWith action = do
  ptr <- sodiumMalloc cryptoAuthKeyBytes
  when (ptr == Foreign.nullPtr) $ do
    throwErrno "sodium_malloc"

  fPtr <- Foreign.newForeignPtr_ ptr
  Foreign.addForeignPtrFinalizer finalizerSodiumFree fPtr
  action ptr
  pure $ AuthenticationKey fPtr

-- | Trigger memory clean up and release without waiting for GC.
--
-- The 'AuthenticationKey' must not be used again.
--
-- @since 0.0.1.0
freeAuthenticationKey :: AuthenticationKey -> IO ()
freeAuthenticationKey (AuthenticationKey fPtr) = Foreign.finalizeForeignPtr fPtr

-- | Create an 'AuthenticationKey' from a binary 'StrictByteString' that you have obtained on your own,
-- usually from the network or disk.
--
-- The input secret key, once decoded from base16, must be of length
-- 'cryptoAuthKeyBytes'.
--
-- @since 0.0.1.0
authenticationKeyFromHexByteString :: StrictByteString -> Either Text AuthenticationKey
authenticationKeyFromHexByteString hexKey = unsafeDupablePerformIO $
  case Base16.decodeBase16Untyped hexKey of
    Right bytestring ->
      if BS.length bytestring == fromIntegral cryptoAuthKeyBytes
        then BS.unsafeUseAsCStringLen bytestring $ \(outsideAuthenticationKeyPtr, _) ->
          fmap Right $
            newAuthenticationKeyWith $ \authenticationKeyPtr ->
              Foreign.copyArray
                (Foreign.castPtr @CUChar @CChar authenticationKeyPtr)
                outsideAuthenticationKeyPtr
                (fromIntegral cryptoAuthKeyBytes)
        else pure $ Left $ Text.pack "Authentication Key is too short"
    Left msg -> pure $ Left msg

-- | Convert a 'AuthenticationKey to a hexadecimal-encoded 'StrictByteString'.
--
-- ⚠️  Be prudent as to where you store it!
--
-- @since 0.0.1.0
unsafeAuthenticationKeyToHexByteString :: AuthenticationKey -> StrictByteString
unsafeAuthenticationKeyToHexByteString (AuthenticationKey authenticationKeyForeignPtr) =
  Base16.extractBase16 . Base16.encodeBase16' $
    BS.fromForeignPtr0
      (Foreign.castForeignPtr @CUChar @Word8 authenticationKeyForeignPtr)
      (fromIntegral @CSize @Int cryptoAuthKeyBytes)

-- | A secret authentication key of size 'cryptoAuthBytes'.
--
-- @since 0.0.1.0
newtype AuthenticationTag = AuthenticationTag (ForeignPtr CUChar)
  deriving
    ( Display
      -- ^ @since 0.0.1.0
    )
    via (ShowInstance AuthenticationTag)

-- |
--
-- @since 0.0.1.0
instance Eq AuthenticationTag where
  (AuthenticationTag hk1) == (AuthenticationTag hk2) =
    unsafeDupablePerformIO $
      foreignPtrEq hk1 hk2 cryptoAuthBytes

-- |
--
-- @since 0.0.1.0
instance Ord AuthenticationTag where
  compare (AuthenticationTag hk1) (AuthenticationTag hk2) =
    unsafeDupablePerformIO $
      foreignPtrOrd hk1 hk2 cryptoAuthBytes

-- |
--
-- @since 0.0.1.0
instance Show AuthenticationTag where
  show = BS.unpackChars . authenticationTagToHexByteString

-- | Convert an 'AuthenticationTag' to a hexadecimal-encoded 'StrictByteString'.
--
-- @since 0.0.1.0
authenticationTagToHexByteString :: AuthenticationTag -> StrictByteString
authenticationTagToHexByteString (AuthenticationTag fPtr) =
  Base16.extractBase16 $
    Base16.encodeBase16' $
      BS.fromForeignPtr0
        (Foreign.castForeignPtr fPtr)
        (fromIntegral cryptoAuthBytes)

-- | Create an 'AuthenticationTag' from a binary 'StrictByteString' that you have obtained on your own,
-- usually from the network or disk.
--
-- The input secret key, once decoded from base16, must be of length
-- 'cryptoAuthBytes'.
--
-- @since 0.0.1.0
authenticationTagFromHexByteString :: StrictByteString -> Either Text AuthenticationTag
authenticationTagFromHexByteString hexTag = unsafeDupablePerformIO $
  case Base16.decodeBase16Untyped hexTag of
    Right bytestring ->
      if BS.length bytestring >= fromIntegral cryptoAuthBytes
        then BS.unsafeUseAsCStringLen bytestring $ \(outsideTagPtr, outsideTagLength) -> do
          hashForeignPtr <- BS.mallocByteString @CChar outsideTagLength -- The foreign pointer that will receive the hash data.
          Foreign.withForeignPtr hashForeignPtr $ \hashPtr ->
            -- We copy bytes from 'outsideTagPtr' to 'hashPtr'.
            Foreign.copyArray hashPtr outsideTagPtr outsideTagLength
          pure $
            Right $
              AuthenticationTag
                (Foreign.castForeignPtr @CChar @CUChar hashForeignPtr)
        else pure $ Left $ Text.pack "Hash is too short"
    Left msg -> pure $ Left msg
