{-# LANGUAGE OverloadedStrings #-}

module Util (
  getEnvStr,
  getEnvBool,
  pad,
  validate,
  between,
  (-$),
  takeLast,
  tabulate
) where

import Data.List
import Data.Maybe
import Data.String
import System.Environment

pad :: Int -> Char -> String -> String
pad n c str = replicate (n - length str) c ++ str

getEnvStr :: String -> String -> IO String
getEnvStr var def = do
  var <- lookupEnv var
  return $ fromMaybe def $ var

getEnvBool :: String -> Bool -> IO Bool
getEnvBool var def = do
  val <- lookupEnv var
  case val of
    Nothing -> pure $ def
    Just "1" -> pure $ True
    Just "0" -> pure $ False
    Just invalid -> error $ "Invalid Bool: " ++ invalid

validate :: [a] -> (a -> Maybe b) -> (a -> e) -> Either e [b]
validate [] _ _ = Right []
validate (x : xs) f onErr = case validate xs f onErr of
  Left err -> Left err
  Right xs -> case f x of
    Nothing -> Left $ onErr x
    Just x  -> Right $ x : xs

between :: Ord a => a -> a -> a -> Bool
between lower x upper = lower <= x && x <= upper

-- XXX: this is from Control.Composition, but basically just doing it
-- here to avoid having to chase down the dependency right this
-- second.
infixl 8 -$
(-$) :: (a -> b -> c) -> b -> a -> c
(-$) f = flip f

-- XXX: This is an orphan instance, but hey it seems to work.
instance IsString a => MonadFail (Either a) where
  fail = Left . fromString

padLeft :: Int -> String -> String
padLeft i s = case i - (length s) of
  0 -> s
  x | x > 0 -> replicate x ' ' ++ s
  _ -> error "negative length"

padRight :: Int -> String -> String
padRight i s = case i - (length s) of
  0 -> s
  x | x > 0 -> s ++ replicate x ' '

padCol :: Int -> [String] -> [String]
padCol i c = padRight i <$> c

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
takeLast Nothing x        = x
takeLast x        Nothing = x
takeLast x        y       = y
