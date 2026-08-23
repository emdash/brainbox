{-# language OverloadedStrings #-}

module Util (
  applyPairwise,
  getEnvBool,
  getEnvStr,
  indent,
  pad,
  padRight,
  prefix,
  between,
  takeLast,
  tabulate,
  validate,
  (-$),
  ($=),
  (=:),
  ($=|),
  (=:|),
) where

import Control.Monad.ST
import Data.IORef
import Data.List
import Data.Maybe
import Data.String
import Data.STRef
import System.Environment

-- | Get env-var from environment as a string, with a default value.
getEnvStr :: String -> String -> IO String
getEnvStr var def = do
  var <- lookupEnv var
  return $ fromMaybe def $ var

-- | Get env-var from enivronment, and try to parse as a bool, with default.
getEnvBool :: String -> Bool -> IO Bool
getEnvBool var def = do
  val <- lookupEnv var
  case val of
    Nothing -> pure $ def
    Just "1" -> pure $ True
    Just "0" -> pure $ False
    Just invalid -> error $ "Invalid Bool: " ++ invalid

-- XXX: is this used?
validate :: [a] -> (a -> Maybe b) -> (a -> e) -> Either e [b]
validate [] _ _ = Right []
validate (x : xs) f onErr = case validate xs f onErr of
  Left err -> Left err
  Right xs -> case f x of
    Nothing -> Left $ onErr x
    Just x  -> Right $ x : xs

-- | Return true if a value is between an upper and lower bound.
between :: Ord a => a -> a -> a -> Bool
between lower x upper = lower <= x && x < upper

-- XXX: this is from Control.Composition, but basically just doing it
-- here to avoid having to chase down the dependency right this
-- second.
infixl 8 -$
(-$) :: (a -> b -> c) -> b -> a -> c
(-$) f = flip f

-- XXX: This is an orphan instance, but hey it seems to work.
instance IsString a => MonadFail (Either a) where
  fail = Left . fromString

-- | Return the given string prefixed with n occurences of c.
--
-- This will cons to the start of the string, so it's optimal compared
-- to `replictate ' ' ++ s`.
prefix :: Int -> Char -> String -> String
prefix x c s | x <= 0 = s
prefix x c s          = ' ' : prefix (x - 1) c s

-- | Return the given string indented by n spaces.
--
-- This will cons to the start of the string, so it's optimal compared
-- to `replictate ' ' ++ s`.
indent :: Int ->  String -> String
indent x = prefix x ' '

-- | Pad the given string with the given char.
pad :: Int -> Char -> String -> String
pad n c str = prefix (n - length str) c str

-- | Like pad, but applies trailing chars.
padRight :: Int -> String -> String
padRight i s = case i - (length s) of
  0 -> s
  x | x > 0 -> s ++ replicate x ' '

-- | Pad an entire column to the given with.
padCol :: Int -> [String] -> [String]
padCol i c = padRight i <$> c

-- | Format the given data into a table.
tabulate :: String -> [[String]] -> String
tabulate colsep rows = intercalate "\n" $ separated
  where
    cols = transpose rows
    widths = (foldl max 0) <$> (length <$>) <$> cols
    padCell (w, c) = padRight w <$> c
    padded = padCell <$> zip widths cols
    separated = intercalate colsep <$> transpose padded
    maxwidth = foldl max 0 $ length <$> separated

-- | Given two maybes, take the right-most non-nothing value
--
-- XXX: feels like a library function that already exists
takeLast :: Maybe a -> Maybe a -> Maybe a
takeLast Nothing x       = x
takeLast x       Nothing = x
takeLast _       y       = y

-- | Step through the given list. For each value, yield the following triple:
--   0. raw value
--   1. f applied to value
--   2. f applied to previous value of x
--
-- This is to allow doing some calculations over previous history,
-- in pure code, avoiding duplication of work.
applyPairwise :: (a -> b) -> b -> [a] -> [(a, b, b)]
applyPairwise _ _    []       = []
applyPairwise f last (x : xs) =
  let x' = f x
  in (x, x', last) : applyPairwise f x' xs

-- | Fun alias for `modifyIORef`
infixr 0 $=

($=) :: IORef a -> (a -> a) -> IO ()
($=) = modifyIORef

-- | Fun alias for `writeIORef`
infixr 0 =:
(=:) :: IORef a -> a -> IO ()
(=:) = writeIORef

infixr 0 $=|
($=|) :: STRef s a -> (a -> a) -> ST s ()
($=|) = modifySTRef

infixr 0 =:|
(=:|) :: STRef s a -> a -> ST s ()
(=:|) = writeSTRef
