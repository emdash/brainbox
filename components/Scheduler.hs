{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}

module Scheduler (
  validateDS,
  preview,
  completionGraph,
  windowArgs
) where

-- import Control.Monad
import Data.Foldable
import Data.Functor
import System.IO
--import Debug.Trace(trace)

import Data.Either.Extra
import Data.Time.Calendar
import Data.Time.Calendar.Month
import Data.Tuple.Utils
import Data.Time.Format

import DateSet
import Interval qualified as I
import Interval(DateTime, TimePeriod(..), (|+), (|-))
import JSONParser qualified as JP
import Parser
import Util

-- | Parse a list of strings into a TimePeriod, taking into account current time.
windowArgs :: I.DateTime -> [String] -> Either String I.TimePeriod
windowArgs now []                = return $ I.TimePeriod (I.startOfDay now) (I.endOfDay now)
windowArgs now ["until", end]    = I.TimePeriod now <$> run parseDateTime end
windowArgs now ["past",  "week"] = return $ I.TimePeriod (now |- 14 * I.day) now
windowArgs now ["past", "month"] = return $ I.TimePeriod (I.prevMonth now) now
windowArgs now ["past", dt]      = I.TimePeriod -$ now <$> run parseDateTime dt
windowArgs now ["this", "week"]  = return $ I.TimePeriod (I.startOfWeek now) (I.endOfWeek now)
windowArgs now ["this", "month"] = return $ I.TimePeriod (I.startOfMonth now) (I.endOfMonth now)
windowArgs now ["since", dt]     = I.TimePeriod -$ now <$> run parseDateTime dt
windowArgs _ [start, end]      =
  pure I.TimePeriod <*> run parseDateTime start <*> run parseDateTime end
windowArgs _ [start, "-", end] =
  pure I.TimePeriod <*> run parseDateTime start <*> run parseDateTime end
windowArgs _ args = Left $ "Invalid Time Window: " ++ show args

validateDS :: String -> IO ()
validateDS encoded = case JP.fromString encoded of
  Right decoded -> putStrLn $ show decoded
  Left  err     -> pErr $ "B:" ++ encoded ++ "|" ++ err

pErr :: String -> IO ()
pErr err = hPutStrLn stderr err

reverseVideo :: String -> String
reverseVideo s = "\x1b[7m" ++ s ++ "\x1b[m"

showMonth :: MonthOfYear -> String
showMonth  1 = "January"
showMonth  2 = "February"
showMonth  3 = "March"
showMonth  4 = "April"
showMonth  5 = "May"
showMonth  6 = "June"
showMonth  7 = "July"
showMonth  8 = "August"
showMonth  9 = "September"
showMonth 10 = "October"
showMonth 11 = "November"
showMonth 12 = "December"
showMonth xx  = error $ "Month out of range: " ++ show xx

formatDay :: Day -> String
formatDay d =
  let day = thd3 $ toGregorian d
  in if day < 10
     then " " ++ show day
     else show day

printDay :: DateSet -> Day -> IO ()
printDay ds day = do
  if DateSet.within ds (I.fromDay day)
    then putStr $ reverseVideo $ formatDay day
    else putStr $ formatDay day
  case dayOfWeek day of
    Saturday -> putStrLn ""
    _      -> putStr " "

previewMonth :: DateSet -> TimePeriod -> IO ()
previewMonth ds w = for_ (I.sequenceMonths w) $ \month -> do
  let (YearMonth y m) = month
  let (first : days) = periodAllDays month
  putStrLn $ showMonth m ++ " " ++ show y
  putStrLn "Su Mo Tu We Th Fr Sa"
  putStr $ (replicate (3 * (fromEnum (dayOfWeek first))) ' ')
  printDay ds first
  for_ days (printDay ds)
  putStr "\n\n"

previewWeek :: DateSet -> TimePeriod -> IO ()
previewWeek ds w = do
  for_ (I.sequenceWeeks w) $ \week -> do
    putStrLn $ formatTime defaultTimeLocale "%Y-%m-%d" (head week)
    putStrLn "      | Su | Mo | Tu | We | Th | Fr | Sa"
    for_ (I.sequenceTime
          (I.hour *  8)
          (I.hour * 23)
          (I.minute * 30)) $ \time -> do
      putStr $ formatTime defaultTimeLocale "%0H:%0M" time ++ " "
      for_ week $ \day -> do
        if DateSet.within ds $ (I.fromDay day) |+ time
          then putStr $ "|" ++ reverseVideo "    "
          else putStr   "|    "
      putStrLn ""
    putStrLn ""

preview :: String -> TimePeriod -> String -> IO ()
preview mode w expr =
  let expr' = case JP.fromString expr of
        Left err -> error err
        Right e -> e
  in case mode of
    "list"  -> for_ (intervals expr' w) $ putStrLn . show
    "month" -> previewMonth expr' w
    "week"  -> previewWeek  expr' w
    bad     -> error $ "invalid mode" ++ bad

completionGraph :: DateSet -> [DateTime] -> TimePeriod -> String
completionGraph self history window = do
  (completions self history window) <&> \(_, complete) ->
    if complete
      then '|'
      else '.'
