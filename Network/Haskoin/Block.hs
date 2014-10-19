{-|
  This package provides block and block-related types.
-}
module Network.Haskoin.Block
( 
  -- * Blocks
  Block(..)
, BlockLocator
, GetBlocks(..)

  -- * Block Headers
, BlockHeader(..)
, GetHeaders(..)
, Headers(..)
, BlockHeaderCount

) where

import Network.Haskoin.Block.Types
