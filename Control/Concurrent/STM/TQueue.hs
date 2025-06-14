{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}
{-# LANGUAGE CPP, DeriveDataTypeable #-}

#if __GLASGOW_HASKELL__ >= 701
{-# LANGUAGE Trustworthy #-}
#endif

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Concurrent.STM.TQueue
-- Copyright   :  (c) The University of Glasgow 2012
-- License     :  BSD-style (see the file libraries/base/LICENSE)
--
-- Maintainer  :  libraries@haskell.org
-- Stability   :  experimental
-- Portability :  non-portable (requires STM)
--
-- A 'TQueue' is like a 'TChan', with two important differences:
--
--  * it has faster throughput than both 'TChan' and 'Chan' (although
--    the costs are amortised, so the cost of individual operations
--    can vary a lot).
--
--  * it does /not/ provide equivalents of the 'dupTChan' and
--    'cloneTChan' operations.
--
-- The implementation is based on the traditional purely-functional
-- queue representation that uses two lists to obtain amortised /O(1)/
-- enqueue and dequeue operations.
--
-- @since 2.4
-----------------------------------------------------------------------------

module Control.Concurrent.STM.TQueue (
        -- * TQueue
        TQueue,
        newTQueue,
        newTQueueIO,
        readTQueue,
        readTQueueN,
        tryReadTQueue,
        flushTQueue,
        peekTQueue,
        tryPeekTQueue,
        writeTQueue,
        unGetTQueue,
        isEmptyTQueue,
  ) where

import GHC.Conc
import Control.Monad (unless)
import Data.Typeable (Typeable)
import Data.Monoid ((<>)) -- Needed by ghc-8.6.5 or earlier

-- | 'TQueue' is an abstract type representing an unbounded FIFO channel.
--
-- @since 2.4
data TQueue a = TQueue {-# UNPACK #-} !(TVar [a])
                       {-# UNPACK #-} !(TVar [a])
  deriving Typeable

instance Eq (TQueue a) where
  TQueue a _ == TQueue b _ = a == b

-- |Build and returns a new instance of 'TQueue'
newTQueue :: STM (TQueue a)
newTQueue = do
  read  <- newTVar []
  write <- newTVar []
  return (TQueue read write)

-- |@IO@ version of 'newTQueue'.  This is useful for creating top-level
-- 'TQueue's using 'System.IO.Unsafe.unsafePerformIO', because using
-- 'atomically' inside 'System.IO.Unsafe.unsafePerformIO' isn't
-- possible.
newTQueueIO :: IO (TQueue a)
newTQueueIO = do
  read  <- newTVarIO []
  write <- newTVarIO []
  return (TQueue read write)

-- |Write a value to a 'TQueue'.
writeTQueue :: TQueue a -> a -> STM ()
writeTQueue (TQueue _read write) a = do
  listend <- readTVar write
  writeTVar write (a:listend)

-- |Read the next value from the 'TQueue'.
readTQueue :: TQueue a -> STM a
readTQueue (TQueue read write) = do
  xs <- readTVar read
  case xs of
    (x:xs') -> do
      writeTVar read xs'
      return x
    [] -> do
      ys <- readTVar write
      case ys of
        [] -> retry
        _  -> do
          let (z:zs) = reverse ys -- NB. lazy: we want the transaction to be
                                  -- short, otherwise it will conflict
          writeTVar write []
          writeTVar read zs
          return z


-- Logic of `readTQueueN`:
--                +-----------+--------------- +-----------------+
--                | write = 0 | write < N-read | write >= N-read |
-- +--------------+-----------+--------------- +-----------------+
-- | read == 0    |  retry    |     retry      |    case 2       |
-- | 0 < read < N |  retry    |     retry      |    case 3       |
-- +--------------+-----------+--------------- +-----------------+
-- | read >= N    |   . . . . . . . case 1 . . . . . . . . .     |
-- +----=--------------------------------------------------------+

-- case 1a: More than N: splitAt N read -> put suffix in read and return prefix
-- case 1b: Exactly N: Reverse write into read, and return all of the old read
-- case 2: Reverse write -> splitAt N, put suffix in read and return prefix
-- case 3: Like case 2 but prepend read onto return value

-- |Reads N values, blocking until enough are available.
-- This is likely never to return if another thread is
-- blocking on `readTQueue`. It has quadratic complexity
-- in N due to each write triggering `readTQueueN` to calculate
-- the length of the write side as <N items pile up there.
--
-- @since 2.5.4
readTQueueN :: TQueue a -> Int -> STM [a]
readTQueueN (TQueue read write) n = do
  xs <- readTVar read
  let xl = length xs
  if xl > n then do -- case 1a
    let (as,bs) = splitAt n xs
    writeTVar read bs
    pure as
  else if xl == n then do -- case 1b
    ys <- readTVar write
    case ys of
      [] -> do 
        writeTVar read []
        retry
      _ -> do
        let zs = reverse ys
        writeTVar write []
        writeTVar read zs
        pure xs
  else do
    ys <- readTVar write
    let yl = length ys
    if yl == 0 then
      retry
    else if yl < n - xl then retry
    else do -- cases 2 and 3    
      let (as,bs) = splitAt (n-xl) (reverse ys)
      writeTVar read bs
      pure $ xs <> as

-- | A version of 'readTQueue' which does not retry. Instead it
-- returns @Nothing@ if no value is available.
tryReadTQueue :: TQueue a -> STM (Maybe a)
tryReadTQueue c = fmap Just (readTQueue c) `orElse` return Nothing

-- | Efficiently read the entire contents of a 'TQueue' into a list. This
-- function never retries.
--
-- @since 2.4.5
flushTQueue :: TQueue a -> STM [a]
flushTQueue (TQueue read write) = do
  xs <- readTVar read
  ys <- readTVar write
  unless (null xs) $ writeTVar read []
  unless (null ys) $ writeTVar write []
  return (xs ++ reverse ys)

-- | Get the next value from the @TQueue@ without removing it,
-- retrying if the channel is empty.
peekTQueue :: TQueue a -> STM a
peekTQueue (TQueue read write) = do
  xs <- readTVar read
  case xs of
    (x:_) -> return x
    [] -> do
      ys <- readTVar write
      case ys of
        [] -> retry
        _  -> do
          let (z:zs) = reverse ys -- NB. lazy: we want the transaction to be
                                  -- short, otherwise it will conflict
          writeTVar write []
          writeTVar read (z:zs)
          return z

-- | A version of 'peekTQueue' which does not retry. Instead it
-- returns @Nothing@ if no value is available.
tryPeekTQueue :: TQueue a -> STM (Maybe a)
tryPeekTQueue c = do
  m <- tryReadTQueue c
  case m of
    Nothing -> return Nothing
    Just x  -> do
      unGetTQueue c x
      return m

-- |Put a data item back onto a channel, where it will be the next item read.
unGetTQueue :: TQueue a -> a -> STM ()
unGetTQueue (TQueue read _write) a = do
  xs <- readTVar read
  writeTVar read (a:xs)

-- |Returns 'True' if the supplied 'TQueue' is empty.
isEmptyTQueue :: TQueue a -> STM Bool
isEmptyTQueue (TQueue read write) = do
  xs <- readTVar read
  case xs of
    (_:_) -> return False
    [] -> do ys <- readTVar write
             case ys of
               [] -> return True
               _  -> return False
