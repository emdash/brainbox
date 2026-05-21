module Util (
  getEnvStr,
  getEnvBool,
  validate
) where

import Data.Maybe
import System.Environment

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
