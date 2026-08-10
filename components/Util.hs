{-# LANGUAGE OverloadedStrings #-}

module Util (
  getEnvStr,
  getEnvBool,
  pad,
  validate,
  between,
  (-$)
) where

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
