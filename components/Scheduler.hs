{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE LambdaCase #-}

module Scheduler (
  validateDS,
  preview,
  completionGraph,
  windowArgs,
  Agenda,
  agenda,
  printAgenda,
  generateIntervals,
  Intervals(..),
  assignSlots,
  toBoundaries,
  Boundary(..),
  Schedule(..)
) where

import Debug.Trace

import Control.Monad.ST
import Data.Bits
import Data.Char(intToDigit)
import Data.Foldable
import Data.Functor
import Data.List qualified as L
import Data.Maybe
import Data.STRef
import Data.Word
import System.IO

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

import DateSet qualified as DS
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

printDay :: DS.DateSet -> Day -> IO ()
printDay ds day = do
  if DS.within ds (I.fromDay day)
    then putStr $ reverseVideo $ formatDay day
    else putStr $ formatDay day
  case dayOfWeek day of
    Saturday -> putStrLn ""
    _      -> putStr " "

previewMonth :: DS.DateSet -> TimePeriod -> IO ()
previewMonth ds w = for_ (I.sequenceMonths w) $ \month -> do
  let (YearMonth y m) = month
  let (first : days) = periodAllDays month
  putStrLn $ showMonth m ++ " " ++ show y
  putStrLn "Su Mo Tu We Th Fr Sa"
  putStr $ (replicate (3 * (fromEnum (dayOfWeek first))) ' ')
  printDay ds first
  for_ days (printDay ds)
  putStr "\n\n"

previewWeek :: DS.DateSet -> TimePeriod -> IO ()
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
        if DS.within ds $ (I.fromDay day) |+ time
          then putStr $ "|" ++ reverseVideo "    "
          else putStr   "|    "
      putStrLn ""
    putStrLn ""

previewDefault :: DS.DateSet -> TimePeriod -> IO ()
previewDefault expr' window = case DS.previewHint expr' of
  DS.L -> for_ (DS.intervals expr' window) $ putStrLn . show
  DS.W -> previewWeek  expr' window
  DS.M -> previewMonth expr' window

preview :: String -> TimePeriod -> String -> IO ()
preview mode window expr =
  let expr' = case JP.fromString expr of
        Left err -> error err
        Right e -> e
  in case mode of
    "default" -> previewDefault expr' window
    "list"  -> for_ (DS.intervals expr' window) $ putStrLn . show
    "month" -> previewMonth expr' window
    "week"  -> previewWeek  expr' window
    bad     -> error $ "invalid mode" ++ bad

completionGraph :: DS.DateSet -> [DateTime] -> TimePeriod -> String
completionGraph self history window = do
  (DS.completions self history window) <&> \(_, complete) ->
    if complete
      then '|'
      else '.'

-- | Return the first available slot in the agenda.
firstSlot :: FiniteBits a => a -> Int
firstSlot w = go 0 where
  go :: Int -> Int
  go b | b >= bitSize w = error "you have too much shit going on"
  go b | testBit w b  = go $ b + 1
  go b = b

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

data Schedule idT = Schedule {
  items  :: ![(idT, (TimePeriod, Int))],
  live   :: !(Map idT (DateTime, Int)),
  stack  :: !(Word64),
  hwm    :: !Int
} deriving (Show)

clear :: Schedule idT
clear = Schedule [] Map.empty 0 0

-- | The information required to display the daily / weekly agenda.
--
-- XXX: the only reason this is parametric in the idT type is that,
-- due to some build system limitations, Scheduler.hs cannot import
-- the `Graph` module, happens to be the current entry point for the
-- whole haskell monolith. This is where `Id` is defined.
data Agenda idT = Agenda {
  glossen     :: !(Map idT String),
  history     :: !(Map idT [I.DateTime]),
  daily       :: !(Schedule idT),
  weekly      :: !(Map idT (Set I.Interval)),
  unscheduled :: !(Set idT)
} deriving (Show)

-- XXX: it is important for this algorithm that we compare the
-- boundary before the id. If all intervals with the same ID are
-- grouped together, we will get perfect interleaving and every Id
-- gets assigned to the first stack slot.
toBoundaries :: Ord idT => Set (idT, I.Interval) -> Set (Boundary, idT)
toBoundaries intervals = foldl' update Set.empty $ Set.toAscList intervals where
  update ret (id', interval) = case interval of
    I.Open        -> Set.insert (NInf, id') ret
    I.Empty       -> ret
    I.LeftOpen  e -> Set.insert (End   e, id') $ Set.insert (NInf, id') ret
    I.RightOpen s -> Set.insert (Start s, id') ret
    I.Closed  s e -> Set.insert (Start s, id') $ Set.insert (End e, id') ret

assignSlots :: Ord idT => Set (Boundary, idT) -> Schedule idT
assignSlots bs = foldl' update init bs where
  init :: Schedule idT
  init = Schedule [] Map.empty 0 0

  update :: Ord idT => Schedule idT -> (Boundary, idT) -> Schedule idT
  update ret (boundary, id') = case boundary of
    NInf -> error "unpossible"
    Start s -> let slot = firstSlot ret.stack in Schedule {
      items = ret.items,
      live  = Map.insert id' (s, slot) ret.live,
      stack = setBit ret.stack slot,
      hwm   = max slot ret.hwm
      }
    End e -> case Map.lookup id' ret.live of
      Nothing -> error "unpossible"
      Just (s, slot) -> Schedule {
        items = (id', ((TimePeriod s e), slot)) : ret.items,
        live      = Map.delete id' ret.live,
        stack     = clearBit ret.stack slot,
        hwm       = ret.hwm
        }

data Intervals idT = Intervals {
  forDay  :: !(Set (idT, I.Interval)),
  forWeek :: !(SetMap idT I.Interval)
  } deriving Show

init' :: Intervals idT
init' = Intervals {
  forDay  = Set.empty,
  forWeek = Map.empty
  }

generateIntervals
  :: (Show idT, Ord idT)
  => DateTime
  -> Map idT [DateTime]
  -> [(idT, DS.DateSet)]
  -> Intervals idT
generateIntervals dt hists stuff =
  let allOfThem = foldl expand Set.empty stuff
      -- (events', habits') = Set.partition ((not . (Map.member -$ hists)) . fst) allOfThem
      (forDay, forWeek)  = Set.partition ((I.contains day') . snd) $ allOfThem
      -- (forWeek, todo) = Set.partition ((I.contains week') . snd) next
  in Intervals forDay (collectSM $ Set.toList forWeek)
  where
    day  = I.TimePeriod (I.startOfDay dt)  (I.endOfDay dt |- 5 * I.minute)
    week = I.TimePeriod (I.startOfWeek dt) (I.endOfWeek dt)

    day'  = I.toInterval day
    week' = I.toInterval week

    smoosh :: Ord idT => idT -> Set (idT, I.Interval) -> I.Interval -> Set (idT, I.Interval)
    smoosh id' ret i = Set.insert (id', i) ret

    expand :: Ord idT => Set (idT, I.Interval) -> (idT, DS.DateSet) -> Set (idT, I.Interval)
    expand ret (id', sch) = foldl' (smoosh id') ret $ DS.intervals sch week

-- | Construct an agenda view for the given input timestamp and task set.
agenda
  :: (Show idT, Ord idT)
  => DateTime
  -> Map idT String
  -> Map idT [DateTime]
  -> [(idT, DS.DateSet)]
  -> Agenda idT
agenda dt glossen hist tasks = Agenda {
    glossen     = glossen,
    history     = hist,
    daily       = assignSlots $ toBoundaries intervals''.forDay,
    weekly      = intervals''.forWeek,
    unscheduled = Set.empty -- intervals''.todo
  } where
    intervals'' = generateIntervals dt hist tasks

-- | Print the agenda to stdout.
printAgenda
  :: (Show idT, Ord idT)
  => Int
  -> Agenda idT
  -> IO ()
printAgenda w agenda' = do
  let hrule = replicate w '\x2550'

  putStrLn hrule
  printDailySchedule w agenda'

  putStrLn hrule
  printWeeklySchedule w agenda'

  {-

  putStrLn hrule
  for_ agenda'.unscheduled $ \id -> do
    putStrLn $ show $ Map.lookup id agenda'.glossen

  putStrLn "Habits"
  putStrLn $ tabulate " | " $ habitTable week glossen $ Map.toList habits'
  where
    habitTable week glossen habits = habitRow week glossen <$> habits

    habitRow week glossen (id, (ds, hist)) = [
      (' ' : ' ' : (fromMaybe "[No Contents]" $ Map.lookup id glossen)),
      (S.completionGraph ds hist week)]
-}

printDailySchedule :: Ord idT => Int -> Agenda idT -> IO ()
printDailySchedule w agenda' =
  condensed
    w
    (lph * 24)
    $ plot ((w - gutter) `div` (agenda'.daily.hwm + 1)) agenda'.glossen <$> agenda'.daily.items
  where
    -- | Time per line in in minutes
    mpl = 5

    -- | Lines per hourd
    lph = 60 `div` mpl

    -- | Horizontal space between items
    margin = 2

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
    schedule []    = R.text "Schedule is Empty"
    schedule rects = R.translate 0 gutter $ R.composite $ R.roundBox ' ' <$> rects

    -- | Render the daily agenda view via inefficient implicit functions.
    --
    -- This method doesn't require any special terminal escape
    -- sequences, but does emit unicode.
    --
    -- This will print the full 24h schedule with now elisions.
    full :: Int -> Int -> [R.LabledRect] -> IO ()
    full w h items = for_
      (R.render w h $ R.overlay backGrid $ schedule items)
      putStrLn

    -- | Print a condensed schedule
    --
    -- This will try to skip empty / repeating areas of the schedule,
    -- so that typical dialy schedules are *much* smaller.
    --
    -- In pathological cases, will be equivalent to
    -- `printFullSchedule`.
    condensed :: Int -> Int -> [R.LabledRect] -> IO ()
    condensed w h items = for_
      (R.renderCondensed w h backGrid $ schedule items)
      putStrLn

printWeeklySchedule :: Ord idT => Int -> Agenda idT -> IO ()
printWeeklySchedule w agenda' = do
  let vals = process <$> Map.toAscList agenda'.weekly
  let img = R.overlay backGrid $ R.translate 2 0 $ R.vertically slotHeight $ item <$> vals

  R.putH stdout w ((Map.size agenda'.weekly) * slotHeight + 3) img
  putStrLn ""
  where
    -- | Time per line in in minutes
    gutter = 20
    colsPerDay = (w - gutter) `div` 7
    margin = 1
    slotHeight = 1

    -- | Calculate the x position for the item, based on calendar day.
    col :: I.DateTime -> Int
    col dt = (colsPerDay * (fromEnum (dayOfWeek $ utctDay dt) - 1)) + ((colsPerDay * (fromEnum $ dt I.|-| I.startOfDay dt)) `div` (fromEnum nominalDay))

    -- | Calculate the height of a rectangle for a given TimeDelta.
    width :: DateTime -> DateTime -> Int
    width s e = colsPerDay * ((fromEnum (e I.|-| s)) `div` (fromEnum nominalDay))

    checkInterval id' i = (any $ I.within i) <$> Map.lookup id' agenda'.history

    completed id' i = (i, checkInterval id' i)

    getCompleted id' = fromJust $ Map.lookup id' agenda'.glossen

    process (id', is) = (getCompleted id', (completed id') <$> Set.toAscList is)

    -- | Convert schedule data to a list of labeled rectangles for drawing.
    item (gloss, intervals) = R.splitH
      gutter
      (Just $ Just '\x2503')
      (R.translate 0 0 $ R.text gloss)
      (R.composite $ uncurry plot <$> intervals)

    occurrence :: Int -> Int -> Maybe Bool -> R.Layer Char
    occurrence x1 x2 comp (0, x) | between x1 x x2 = case comp of
      Just True  -> Just '\x2588'
      Just False -> Just '\x2592'
      Nothing    -> Just '\x254c'
    occurrence _  _  _    _      = Nothing

    plot :: I.Interval -> Maybe Bool -> R.Layer Char
    plot (I.Empty      ) completed _ = Nothing
    plot (I.Open       ) completed _ = Nothing -- Just 'X'
    plot (I.LeftOpen  e) completed _ = Nothing -- Just 'X'
    plot (I.RightOpen s) completed _ = Nothing -- Just 'X'
    plot (I.Closed  s e) completed p = occurrence (col s) (col e) completed p
    plot _               completed _ = Nothing

    -- | Render the y-axis labels
    dayLabels :: R.Layer Char
    dayLabels = R.translate 0 (gutter + 1) $ R.text $ ' ' : (L.intercalate "\x2502" $ padRight (colsPerDay - 1) <$> take 2 <$> show <$> enumFromTo Monday Sunday)

    dayGrid :: R.Image
    dayGrid (1, x) | x > gutter + 1 = case (x - gutter - 1) `mod` colsPerDay of
      0 -> '\x2534'
      _ -> '\x2500'
    dayGrid (1, x) | x <= gutter + 1 = '\x2500'
    dayGrid (_, x) | x > (gutter + 1) = case (x - gutter - 1) `mod` colsPerDay of
      0 -> '\x2506'
      _ -> ' '

    dayGrid (y, x) | y `mod` slotHeight == 1 && x < gutter = '\x2500'
    dayGrid _ = ' '

    -- | Render background grid and left-side gutter
    backGrid :: R.Image
    backGrid = R.overlay dayGrid dayLabels
