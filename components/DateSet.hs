{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}


module DateSet (
  DateSet,
  IDateSet(..),
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

import Data.Fixed
import Data.Foldable
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe
import Data.Set (Set)
import qualified Data.Set as Set

import Data.Time.Clock
import Data.Time.Calendar
import Data.Time.Calendar.Month
import Data.Time.LocalTime

import Util
import Interval (
  IWithin(..),
  Interval(..),
  DateTime,
  TimeDelta, (|+), (|-), (|-|))
import qualified Interval as Interval

-- | The methods that are supported by DateSet
class Show a => IDateSet a where
  -- | Return the smallest interval spanning the entire set.
  span :: a -> Interval
  span _ = Open

  -- | True if window interesects any interval within the dateset.
  intersects :: a -> Interval -> Bool

  -- | Return the largest interval in the dateset containing the given time.
  largestIntervalContaining :: a -> DateTime -> Interval

  -- | Return an ordered sequence of intervals which intersect
  intervals :: a -> Interval -> [Interval]

  -- | Return the inverted equivalent of the given interval
  invert :: a -> DateSet

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
  intervals (DateSet ds) = intervals ds
  invert (DateSet ds) = invert ds

instance IWithin DateSet where
  -- | True if the DateSet contains the given instant.
  within :: DateSet -> DateTime -> Bool
  within (DateSet ds) dt = within (largestIntervalContaining ds dt) dt

-- | True if the dateset is finite.
finite :: DateSet -> Bool
finite (DateSet ds) = Interval.finite $ DateSet.span ds

-- | Yield tuples of `(intervals, completed)`.
--
-- A single timestamp within an interval is considered a "completion
-- event", which discharges the obligation implied by the interval.
--
-- Multiple timestamps within an interval are ignored, as are
-- timestamps outside of a completion window.
--
-- `window` is treated the same as in `intervals`.
completions :: DateSet -> [DateTime] -> Interval -> [(Interval, Bool)]
completions self history window = completed <$> intervals self window
  where
    completed i = (i, any (within i) history)

-- | True if all intervals within the window have a completion event.
isComplete :: DateSet -> [DateTime] -> Interval -> Bool
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
    filter (Interval.intersects w) $ Set.toAscList intervals

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

  intervals = undefined

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

  intervals = undefined

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

  intersects self w  = not $ null $ intervals self w
  intervals = undefined

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
  which :: Set DayOfWeek
} deriving Show

instance IDateSet Weekly where
  largestIntervalContaining self dt =
    if Set.member (dayOfWeek dt.utctDay) self.which
      then Interval.fromDate dt Nothing
      else Empty

  intersects self w = not $ null $ intervals self w
  intervals = undefined

weekly :: Set DayOfWeek -> DateSet
weekly = DateSet . Weekly
-------------------------------------------------------------------------------

-- | A DateSet representing a monthly pattern.
data Monthly = Monthly {
  months :: Map MonthOfYear (Set DayOfMonth)
} deriving Show

instance IDateSet Monthly where
  largestIntervalContaining self dt =
    let
      (y, m, _) = toGregorian (utctDay dt)
      days      = fromMaybe Set.empty $ Map.lookup m self.months
      intervals = Interval.mergeConsecutive $
            Interval.fromDate -$ Nothing
        <$> UTCTime -$ (fromInteger 0)
        <$> fromGregorian y m
        <$> Set.toAscList days
    in fromMaybe Empty $ find (within -$ dt) intervals

  intersects self w = not $ null $ intervals self w
  intervals = undefined

monthly :: Map MonthOfYear (Set DayOfMonth) -> DateSet
monthly = DateSet . Monthly

-------------------------------------------------------------------------------

-- | Repeats on the nth week day of the given month.
data NthWeekday = NthWeekday {
  n :: Int,
  weekday :: DayOfWeek,
  month :: Maybe DayOfMonth
} deriving Show

instance IDateSet NthWeekday where
  largestIntervalContaining (NthWeekday n wd m) dt@(UTCTime d _) =
    if dayOfWeek d == wd
    then
      let
        (year, month, day) = toGregorian d
        month' = fromMaybe month m
        nd = _nthWeekday (toInteger n) wd month' year
      in if d == nd
         then Interval.fromDate dt Nothing
         else Empty
    else Empty

  intersects self w = not $ null $ intervals self w
  intervals = undefined

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
nthWeekday n d m = DateSet $ NthWeekday n d m

-------------------------------------------------------------------------------

-- | Shift the given dateset by a fixed amount of time.
data Shift = Shift {
  offset :: TimeDelta,
  subset :: DateSet
} deriving Show

instance IDateSet Shift where
  largestIntervalContaining self dt =
    largestIntervalContaining self.subset $ (dt |- self.offset) |+ self.offset

  intersects self w = not $ null $ intervals self w
  intervals = undefined

shift :: TimeDelta -> DateSet -> DateSet
shift td ds = DateSet $ Shift td ds

-------------------------------------------------------------------------------
