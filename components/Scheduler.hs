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
  windowArgs,
  agendaDay,
  Agenda(..)
) where


import Debug.Trace
-- import Control.Monad
import Data.Bits
import Data.Foldable
import Data.Functor
import Data.Word
import System.IO

--import Debug.Trace(trace)

import Data.Either.Extra
import Data.Map(Map)
import Data.Map qualified as Map
import Data.Set(Set)
import Data.Set qualified as Set
import Data.Time.Calendar
import Data.Time.Calendar.Month
import Data.Time.Clock
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
preview mode window expr =
  let expr' = case JP.fromString expr of
        Left err -> error err
        Right e -> e
  in case mode of
    "list"  -> for_ (intervals expr' window) $ putStrLn . show
    "month" -> previewMonth expr' window
    "week"  -> previewWeek  expr' window
    bad     -> error $ "invalid mode" ++ bad

completionGraph :: DateSet -> [DateTime] -> TimePeriod -> String
completionGraph self history window = do
  (completions self history window) <&> \(_, complete) ->
    if complete
      then '|'
      else '.'

data Boundary
  = NInf
  | Start DateTime
  | End DateTime
  deriving (Eq, Show)

instance Ord Boundary where
  compare NInf _ = LT
  compare _ NInf = GT
  compare (Start l) (Start r) = compare l r
  compare (Start l) (End r) = case compare l r of
    EQ -> LT
    x  -> x
  compare (End l) (Start r) = case compare l r of
    EQ -> GT
    x  -> x
  compare (End l) (End r) = compare l r

data Agenda idT = Agenda {
  scheduled :: [(idT, (TimePeriod, Int))],
  allDay :: Set idT,
  live :: Map idT (DateTime, Int),
  stack :: Word8,
  hwm :: Int
} deriving Show

firstSlot :: Word8 -> Int
firstSlot w = go True (w .&. 0x0F)
  where
    go _     0b0000 = 0
    go _     0b0001 = 1
    go _     0b0010 = 0
    go _     0b0011 = 2
    go _     0b0100 = 0
    go _     0b0101 = 1
    go _     0b0110 = 0
    go _     0b0111 = 3
    go _     0b1000 = 0
    go _     0b1001 = 1
    go _     0b1010 = 0
    go _     0b1011 = 2
    go _     0b1100 = 0
    go _     0b1101 = 1
    go _     0b1110 = 0
    go True  _      = (go False (shiftR w 4)) + 4
    go False 0b1111 = error "you have too much shit going on"
    go y     x      = error $ "wtf" ++ show x ++ show y

blank :: Agenda a
blank = Agenda [] Set.empty Map.empty 0 0

punt :: Ord idT => idT -> Agenda idT -> Agenda idT
punt i self = self { allDay = Set.insert i self.allDay }

push :: Ord idT => idT -> DateTime -> Agenda idT -> Agenda idT
push i start self =
  let
    slot = firstSlot self.stack
  in self {
    live  = Map.insert i (start, slot) self.live,
    stack = setBit self.stack slot,
    hwm   = max self.hwm slot
  }

pop :: Ord idT => idT -> DateTime -> Agenda idT -> Agenda idT
pop i e self = case Map.lookup i self.live of
  Nothing -> error "End without start"
  Just (s, slot) -> self {
    scheduled = (i, ((TimePeriod s e), slot)) : self.scheduled,
    live = Map.delete i self.live,
    stack = clearBit self.stack slot
  }

toBoundaries :: Ord idT => [(idT, I.Interval)] -> (Set (Boundary, idT), Set idT)
toBoundaries intervals = let x = foldl byCases (Set.empty, Set.empty) intervals in x
  where
    byCases (b, ad) (i, I.Open)        = (Set.insert (NInf, i) b, ad)
    byCases ret     (_, I.Empty )      = ret
    byCases (b, ad) (i, I.LeftOpen e)  = (Set.insert (End e, i) $ Set.insert (NInf, i) b, ad)
    byCases (b, ad) (i, I.RightOpen s) = (b, Set.insert i ad)
    byCases (b, ad) (i, I.Closed s e)  =
      if e I.|-| s < (I.day - 5 * I.minute)
      then (Set.insert (End e, i) $ Set.insert (Start s, i) b, ad)
      else (b, Set.insert i ad)

agendaDay :: Ord idT => DateTime -> [(idT, DateSet)] -> Agenda idT
agendaDay day sched =
  let (boundaries, ad) = toBoundaries intervals
  in foldl update (blank {allDay = ad}) $ Set.toAscList $ boundaries
  where
    collectIntervals horizon ret (i, ds) =
      foldl (\acc interval -> (i, interval) : acc) ret $
        DateSet.intervals ds horizon

    horizon :: I.TimePeriod
    horizon = TimePeriod (I.startOfDay day) (I.endOfDay day)

    -- intervals :: [(idT, I.Interval)]
    intervals = foldl (collectIntervals horizon) [] $ sched

    update ret (NInf, i)    = punt i   ret
    update ret (Start s, i) = push i s ret
    update ret (End e, i)   = pop  i e ret
