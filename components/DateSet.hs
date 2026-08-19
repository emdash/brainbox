{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}


module DateSet (
  PreviewHint(..),
  DateSet,
  IDateSet(..),
  _intervals,
  within,
  finite,
  explicit,
  union,
  intersection,
  periodic,
  atTime,
  weekly,
  monthly,
  nthWeekday,
  shift,
  completions,
  isComplete,
) where

import Data.Bits qualified as Bits
import Data.Fixed
import Data.Foldable
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Word
-- import Debug.Trace(trace)

import Data.Time.Clock
import Data.Time.Calendar
import Data.Time.Calendar.Month
import Data.Time.LocalTime

import Util
import Interval (
  IWithin(..),
  Interval(..),
  TimePeriod(..),
  DateTime,
  TimeDelta,
  (|+), (|-), (|-|),
  toInterval)
import Interval qualified as Interval

data PreviewHint = W | M | L
  deriving (Ord, Eq, Show)

-- | The methods that are supported by DateSet
class Show a => IDateSet a where
  -- | Return the smallest interval spanning the entire set.
  span :: a -> Interval
  span _ = Open

  -- | True if window interesects any interval within the dateset.
  intersects :: a -> Interval -> Bool
  intersects self w  = case w of
    Empty -> False
    Closed s e -> not $ null $ intervals self $ TimePeriod s e
    _ -> True

  -- | Return the largest interval in the dateset containing the given time.
  largestIntervalContaining :: a -> DateTime -> Interval

  -- | Return an ordered sequence of intervals which intersect
  intervals :: a -> TimePeriod -> [Interval]
  intervals = _intervals

  -- | Return the inverted equivalent of the given interval
  invert :: a -> DateSet

  -- | A hint to the scheduler about how often to sample
  _dur :: a -> TimeDelta
  _dur _ = 1 * Interval.minute

  previewHint :: a -> PreviewHint
  previewHint _ = L

-- | Represents when an event can happen.
--
-- We can ask a date set whether or not an arbitrary interval
-- intersects it, and we can ask for the set for all the intervals it
-- contains which intersect the window.
--
-- A DateSet can be finite or infinite. For finite sets, we can find
-- the span (i.e. bounding interval, or the smallest interval that
-- contains every interval in the set).
data DateSet
  where DateSet :: IDateSet a => a -> DateSet

instance Show DateSet where
  show (DateSet ds) = show ds

instance IDateSet DateSet where
  intersects (DateSet ds) w = intersects ds w
  span (DateSet ds) = DateSet.span ds
  largestIntervalContaining (DateSet ds) = largestIntervalContaining ds
  invert (DateSet ds) = invert ds
  previewHint (DateSet ds) = previewHint ds

instance IWithin DateSet where
  -- | True if the DateSet contains the given instant.
  within :: DateSet -> DateTime -> Bool
  within (DateSet ds) dt = within (largestIntervalContaining ds dt) dt

-- | True if the dateset is finite.
finite :: DateSet -> Bool
finite (DateSet ds) = Interval.finite $ DateSet.span ds

_intervals :: IDateSet a => a -> TimePeriod -> [Interval]
_intervals self (TimePeriod s e) = Interval.mergeConsecutive $ go s []
  where
    dur = _dur self
    go i ret | i < e = case largestIntervalContaining self i of
      Empty       -> go (i |+ dur) ret
      Open        -> [Open]
      LeftOpen  e -> [LeftOpen e]
      RightOpen s -> (RightOpen s) : ret
      Closed  s e -> go (e |+ dur) $ (Closed s e) : ret
    go _ ret = reverse ret

-- | Yield tuples of `(intervals, completed)`.
--
-- A single timestamp within an interval is considered a "completion
-- event", which discharges the obligation implied by the interval.
--
-- Multiple timestamps within an interval are ignored, as are
-- timestamps outside of a completion window.
--
-- `window` is treated the same as in `intervals`.
completions :: DateSet -> [DateTime] -> TimePeriod -> [(Interval, Bool)]
completions self history window = completed <$> _intervals self window
  where
    completed i = (i, any (within i) history)

-- | True if all intervals within the window have a completion event.
isComplete :: DateSet -> [DateTime] -> TimePeriod -> Bool
isComplete self history window = go window
  where
    go window = all snd $ completions self history window

-------------------------------------------------------------------------------

-- | A DateSet representing an explicit set of intervals.
data Explicit = Explicit (Set Interval) deriving Show

instance IDateSet Explicit where
  intersects (Explicit intervals) i = any (Interval.intersects i) intervals
  span (Explicit intervals) = foldl Interval.span Empty intervals
  largestIntervalContaining (Explicit intervals) dt =
    fromMaybe Empty $ find (within -$ dt) intervals

  intervals (Explicit intervals) w =
    filter (Interval.intersects $ toInterval w) $ Set.toAscList intervals

  invert (Explicit intervals) = explicit $ go $ Set.toAscList intervals
    where
      go [] = []
      go (x : xs) = case Interval.invert x of
        Left       x' -> x' : go xs
        Right (x', y) -> x' : y : go xs

explicit :: [Interval] -> DateSet
explicit intervals = DateSet
  $ Explicit
  $ Set.fromList
  $ Interval.mergeConsecutive intervals

-------------------------------------------------------------------------------

-- | A DateSet representing the union of multiple datesets.
data Union = Union [DateSet] deriving Show

instance IDateSet Union where
  intersects (Union subsets) i = any (intersects -$ i) subsets
  largestIntervalContaining (Union subsets) dt =
    foldl Interval.span Empty $ (largestIntervalContaining -$ dt) <$> subsets
  span (Union subsets)        = foldl unSpan  Empty subsets
    where unSpan ret s = Interval.span (DateSet.span s) ret

  _dur (Union subsets) = foldl min Interval.day $ _dur <$> subsets

  previewHint (Union subsets) = foldl max L $ previewHint <$> subsets

union :: [DateSet] -> DateSet
union = DateSet . Union

-------------------------------------------------------------------------------

-- | A DateSet representing the intersection of multiple datesets.
data Intersection = Intersection [DateSet] deriving Show

instance IDateSet Intersection where
  span (Intersection subsets) = foldl intSpan Open  subsets
    where
      intSpan ret s = case DateSet.span s of
        Empty -> Empty
        Open  -> ret
        i     -> Interval.intersection ret i

  intersects (Intersection subsets) i = all (intersecting i) subsets
    where
      intersecting :: Interval -> DateSet -> Bool
      intersecting i ds = DateSet.intersects ds i

  largestIntervalContaining (Intersection subsets) dt = foldl go Open $ subsets
    where go acc i = Interval.intersection acc (largestIntervalContaining i dt)

  _dur (Intersection subsets) = foldl min Interval.day $ _dur <$> subsets

  previewHint (Intersection subsets) = foldl min L $ previewHint <$> subsets

intersection :: [DateSet] -> DateSet
intersection = DateSet . Intersection

-------------------------------------------------------------------------------

-- | A DateSet representing a regular period of time.
data Periodic = Periodic {
  period :: TimeDelta,
  duration :: TimeDelta,
  phase :: TimeDelta
} deriving Show

instance IDateSet Periodic where
  largestIntervalContaining self dt =
    let as_delta = dt |-| Interval.origin
        start    = Interval.origin |+
          (as_delta - ((as_delta - self.phase) `mod'` self.period))
        end      = start |+ self.duration
    in if between start dt end
       then Closed start end
       else Empty

  intersects self w  = case w of
    Empty -> False
    Closed s e -> not $ null $ intervals self $ TimePeriod s e
    _ -> True

  -- XXX:
  -- swaps phase and duration, keeping period the same.
  -- I think this works in all cases, but this needs to be tested.
  --
  -- good case for a property test
  invert self = periodic self.period self.phase $ Just self.duration

  _dur self = min self.phase $ self.duration - self.phase

  previewHint self | self.period <= Interval.day  = W
  previewHint self | self.period <= Interval.week = M
  previewHint _                                   = L

-- | A DateSet which repeats over a fixed period, for the given
-- duration, offset by an optional phase.
periodic :: TimeDelta -> TimeDelta -> Maybe TimeDelta -> DateSet
periodic period duration' (Just phase) = DateSet $ Periodic period duration' phase
periodic period duration' Nothing      = DateSet $ Periodic period duration' (fromInteger 0)

-- | A special-case of periodic, which occurs at a particular time each day.
atTime :: TimeOfDay -> TimeDelta -> Bool -> DateSet
atTime time dur inverted =
  let start = daysAndTimeOfDayToTime 0 time
      base = DateSet $ Periodic Interval.day dur start
  in if inverted then invert $ base else base

-------------------------------------------------------------------------------

-- | A DateSet representing a weekly pattern.
data Weekly = Weekly {
  which :: Word8
} deriving Show

instance IDateSet Weekly where
  largestIntervalContaining self dt =
    if Bits.testBit self.which $ fromEnum $ (dayOfWeek dt.utctDay)
      then Interval.fromDate dt Nothing
      else Empty

  invert self = DateSet $ Weekly $ Bits.complement self.which

  _dur _ = Interval.day

  previewHint _ = M

toWord8 :: Set DayOfWeek -> Word8
toWord8 days = foldl insert_ 0 days
  where
    insert_ x wd = Bits.setBit x $ fromEnum wd

weekly :: Set DayOfWeek -> DateSet
weekly = DateSet . Weekly . toWord8

-------------------------------------------------------------------------------

-- | A DateSet representing a monthly pattern.
data Monthly = Monthly {
  months :: Map MonthOfYear Word32
} deriving Show

instance IDateSet Monthly where
  largestIntervalContaining self dt =
    let
      (y, m, _) = toGregorian (utctDay dt)
      days      = fromMaybe 0 $ Map.lookup m self.months
      intervals = Interval.mergeConsecutive $
            Interval.fromDate -$ Nothing
        <$> UTCTime -$ (fromInteger 0)
        <$> fromGregorian y m
        <$> fromWord32 days
    in fromMaybe Empty $ find (within -$ dt) intervals

  invert self = DateSet $ Monthly $ Map.map Bits.complement self.months

  _dur _ = Interval.day

  previewHint _ = M

fromWord32 :: Word32 -> [DayOfMonth]
fromWord32 days = filter (Bits.testBit days) [1..31]

toWord32 :: Set DayOfMonth -> Word32
toWord32 days = foldl insert_ 0 days
  where
    insert_ x dom = Bits.setBit x $ fromEnum dom

monthly :: Map MonthOfYear (Set DayOfMonth) -> DateSet
monthly months = DateSet $ Monthly $ Map.map toWord32 months

-------------------------------------------------------------------------------

-- | Repeats on the nth week day of the given month.
data NthWeekday = NthWeekday {
  n :: Int,
  weekday :: DayOfWeek,
  month :: Maybe DayOfMonth,
  inverted :: Bool
} deriving Show

instance IDateSet NthWeekday where
  largestIntervalContaining (NthWeekday n wd m False) dt@(UTCTime d _) =
    if dayOfWeek d == wd
    then
      let
        (year, month, _) = toGregorian d
        month' = fromMaybe month m
        nd = _nthWeekday (toInteger n) wd month' year
      in if d == nd
         then Interval.fromDate dt Nothing
         else Empty
    else Empty

  largestIntervalContaining (NthWeekday n wd m True) (UTCTime d _) =
    let
      (year, month, _) = toGregorian d
      month' = fromMaybe month m
      month'' = YearMonth year month'
      first = periodFirstDay month''
      last = periodLastDay month''
      nd = _nthWeekday (toInteger n) wd month' year
      mn = fromInteger 0
    in case compare d nd of
      LT -> Closed
       (UTCTime first    mn)
       (UTCTime (pred d) mn)
      EQ -> Empty
      GT -> Closed
       (UTCTime (succ d) mn)
       (UTCTime last     mn)

  invert self = DateSet $ self {inverted = not self.inverted}

  _dur _ = Interval.day

  previewHint _ = M

firstWeekday :: DayOfWeek -> Month -> Day
firstWeekday d m = go $ periodFirstDay m
  where
    go e = if (dayOfWeek e) == d
      then e
      else go $ succ e

lastWeekday :: DayOfWeek -> Month -> Day
lastWeekday d m = go $ periodLastDay m
  where
    go e = if (dayOfWeek e) == d
      then e
      else go $ pred e

_nthWeekday :: Integer -> DayOfWeek -> MonthOfYear -> Year -> Day
_nthWeekday n weekday month year
  | n > 0 = ((n - 1) * 7) `addDays`
            (firstWeekday weekday $ YearMonth year month)
  | n < 0 = (((abs n) - 1) * 7) `addDays`
            (lastWeekday  weekday $ YearMonth year month)
_nthWeekday _ _ _ _ = error "N cannot be 0"

nthWeekday :: Int -> DayOfWeek -> Maybe DayOfMonth -> DateSet
nthWeekday n d m = DateSet $ NthWeekday n d m False

-------------------------------------------------------------------------------

-- | Shift the given dateset by a fixed amount of time.
data Shift = Shift {
  offset :: TimeDelta,
  subset :: DateSet
} deriving Show

instance IDateSet Shift where
  largestIntervalContaining self dt =
    largestIntervalContaining self.subset $ (dt |- self.offset) |+ self.offset

  invert self = shift self.offset $ invert self.subset

  previewHint self = previewHint self.subset

shift :: TimeDelta -> DateSet -> DateSet
shift td ds = DateSet $ Shift td ds

-------------------------------------------------------------------------------
