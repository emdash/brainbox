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
  Agenda(..),
  agenda,
  printAgenda,
) where


import Debug.Trace
-- import Control.Monad
import Data.Bits
import Data.Char(intToDigit)
import Data.Foldable
import Data.Functor
import Data.Maybe
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
import Data.Tuple.Extra
import Data.Time.Format

import DateSet
import Interval qualified as I
import Interval(DateTime, TimePeriod(..), (|+), (|-))
import JSONParser qualified as JP
import Parser
import Render qualified as R
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

previewDefault :: DateSet -> TimePeriod -> IO ()
previewDefault expr' window = case previewHint expr' of
  L -> for_ (intervals expr' window) $ putStrLn . show
  W -> previewWeek  expr' window
  M -> previewMonth expr' window

preview :: String -> TimePeriod -> String -> IO ()
preview mode window expr =
  let expr' = case JP.fromString expr of
        Left err -> error err
        Right e -> e
  in case mode of
    "default" -> previewDefault expr' window
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

-- | The information required to display the daily / weekly agenda.
--
-- XXX: the only reason this is parametric in the idT type is that,
-- due to some build system limitations, Scheduler.hs cannot import
-- the `Graph` module, happens to be the current entry point for the
-- whole haskell monolith. This is where `Id` is defined.
data Agenda idT = Agenda {
  scheduled :: [(idT, (TimePeriod, Int))],
  allDay :: Set idT,
  live :: Map idT (DateTime, Int),
  stack :: Word8,
  hwm :: Int
} deriving Show

-- | Return the first available slot in the agenda.
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

-- | Construct a blank agenda.
blank :: Agenda a
blank = Agenda [] Set.empty Map.empty 0 0

-- | Punt the given task from the daily schedule to the weekly.
punt :: Ord idT => idT -> Agenda idT -> Agenda idT
punt i self = self { allDay = Set.insert i self.allDay }

-- | Log the start of a new task while constructing an agenda.
push :: Ord idT => idT -> DateTime -> Agenda idT -> Agenda idT
push i start self =
  let
    slot = firstSlot self.stack
  in self {
    live  = Map.insert i (start, slot) self.live,
    stack = setBit self.stack slot,
    hwm   = max self.hwm slot
  }

-- | Log the end of an existing task while constructing an agenda.
pop :: Ord idT => idT -> DateTime -> Agenda idT -> Agenda idT
pop i e self = case Map.lookup i self.live of
  Nothing -> error "End without start"
  Just (s, slot) -> self {
    scheduled = (i, ((TimePeriod s e), slot)) : self.scheduled,
    live = Map.delete i self.live,
    stack = clearBit self.stack slot
  }

-- | Explode the given list of intervals to an ordered set of boundaries.
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

-- | Construct an agenda view for the given input timestamp and task set.
agenda :: Ord idT => DateTime -> [(idT, DateSet)] -> Agenda idT
agenda day sched =
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

{-
  putStrLn "All Day"
  for_ ad.allDay $ \id -> putStrLn $ (' ' : ' ' : (fromMaybe "[No contents]" $ Map.lookup id glossen))
  putStrLn ""

  putStrLn "Habits"
  putStrLn $ tabulate " | " $ habitTable week glossen $ Map.toList habits'
  where
    habitTable week glossen habits = habitRow week glossen <$> habits

    habitRow week glossen (id, (ds, hist)) = [
      (' ' : ' ' : (fromMaybe "[No Contents]" $ Map.lookup id glossen)),
      (S.completionGraph ds hist week)]

  let ad =
  let week =
-}

-- | Print the agenda to stdout.
printAgenda
  :: Ord idT
  => Int
  -> Map idT String
  -> Agenda idT
  -> I.TimePeriod
  -> IO ()
printAgenda w glossen ad week = do
  let hrule = replicate w '\x2550'
  putStrLn hrule
  printCondensedSchedule
    w
    (lph * 24)
    $ plot ((w - gutter) `div` (ad.hwm + 1)) glossen <$> ad.scheduled
  putStrLn hrule
  where
    -- | Time per line in in minutes
    mpl = 5

    -- | Lines per hour
    lph = 60 `div` mpl

    -- | Horizontal space between items
    margin = 2

    -- | Half the margin.
    marginH = margin `div` 2

    -- | Width of left gutter
    gutter = 6

    -- | Calculate the y position for the given timestamp.
    row :: I.DateTime -> Int
    row dt =
      let (UTCTime _ time) = dt
      in  (fromEnum time) `div` 1_000_000_000_000 `div` 60 `div` mpl

    -- | Calculate the x column position of the left edge of the given slot index.
    col :: Int -> Int -> Int
    col slotWidth slot = slotWidth * slot

    -- | Calculate the height of a rectangle for a given TimeDelta.
    height :: I.TimeDelta -> Int
    height td = (fromEnum td) `div` 1_000_000_000_000 `div` 60 `div` mpl

    -- | Convert schedule data to a list of labeled rectangles for drawing.
    plot :: Ord idT => Int -> Map idT String -> (idT, (I.TimePeriod, Int)) -> R.LabledRect
    plot slotWidth glossen (id, (I.TimePeriod s e, slot)) =
      R.rect
        (fromJust $ Map.lookup id glossen)
        (col slotWidth slot)
        (row s)
        (slotWidth - margin)
        (height $ e I.|-| s)

    -- | Render the y-axis labels
    timeLabels :: R.Layer Char
    timeLabels (y, x) =
      let elapsed = mpl * y
      in if elapsed `mod` 15 == 0
         then
           let (hours, minutes) = divMod elapsed 60
               (h0, h1)         = both intToDigit $ divMod hours 10
               (m0, m1)         = both intToDigit $ divMod minutes 10
               timestr = (pad 2 '0' $ show hours) ++ (':' : (pad 2 '0' $ show minutes)) ++ " "
           in case x of
             0 -> Just h0
             1 -> Just h1
             2 -> Just ':'
             3 -> Just m0
             4 -> Just m1
             _ -> Nothing
         else if x == 2 then Just '\x2502' else Nothing

    timeGrid :: R.Image
    timeGrid (y, _) = case y `mod` lph of
      0 -> '\x2504'
      6 -> '\x2504'
      _ -> ' '

    -- | Render background grid and left-side gutter
    backGrid :: R.Image
    backGrid = R.overlay timeGrid timeLabels

    -- | Render the schedule items layer
    schedule :: [R.LabledRect] -> R.Layer Char
    schedule []           = R.text "Schedule is Empty"
    schedule (bot : rest) = R.translate 0 gutter $ R.composite (R.roundBox ' ' bot) $ R.roundBox ' ' <$> rest

    -- | Render the daily agenda view via inefficient implicit functions.
    --
    -- This method doesn't require any special terminal escape
    -- sequences, but does emit unicode.
    --
    -- This will print the full 24h schedule with now elisions.
    printFullSchedule :: Int -> Int -> [R.LabledRect] -> IO ()
    printFullSchedule w h items = for_
      (R.render w h $ R.overlay backGrid $ schedule items)
      putStrLn

    -- | Print a condensed schedule
    --
    -- This will try to skip empty / repeating areas of the schedule,
    -- so that typical dialy schedules are *much* smaller.
    --
    -- In pathological cases, will be equivalent to
    -- `printFullSchedule`.
    printCondensedSchedule :: Int -> Int -> [R.LabledRect] -> IO ()
    printCondensedSchedule w h items = for_
      (R.renderCondensed w h backGrid $ schedule items)
      putStrLn
