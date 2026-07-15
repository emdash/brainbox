module DateSet (
  DateSet(..),
  finite,
  intersects,
  DateSet.span,
  resolution,
  within,
  contains,
  intervals,
  completions,
  isComplete,
  largestIntervalContaining,
  invert
) where

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set

import Data.Time.Clock
import Data.Time.Calendar.OrdinalDate
import Data.Time.Calendar
import Data.Time.Format.ISO8601
import Data.Time.LocalTime

import Interval (Interval, DateTime, TimeDelta)
import qualified Interval as Interval

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
  = Explicit (Set Interval)
  | Union [DateSet]
  | Intersection [DateSet]
  | Periodic {period :: TimeDelta, duration :: TimeDelta, phase :: TimeDelta}
  | AtTime {start :: TimeOfDay, duration' :: TimeDelta, inverted :: Bool}
  | Weekly {which :: Set DayOfWeek, multi_day :: Bool}
  | Monthly {months :: Map MonthOfYear (Set DayOfMonth)}
  | NthWeekday {n :: Int, weekday :: DayOfWeek, month :: Maybe DayOfMonth}
  | Shift {offset :: TimeDelta, subset :: DateSet}
  deriving (Eq, Ord, Show)

-- | True if the dateset is finite.
finite :: DateSet -> Bool
finite (Explicit intervals) = all Interval.finite intervals
finite (Union subsets) = all DateSet.finite subsets
finite (Intersection subsets) = any DateSet.finite subsets
finite (Shift _ subset) = DateSet.finite subset
finite _ = False

-- | True if window interesects any interval within the dateset.
intersects :: DateSet -> Interval -> Bool
intersects (Explicit intervals) i = any (Interval.intersects i) intervals
intersects (Union subsets) i = any (intersecting i) subsets
  where
    intersecting :: Interval -> DateSet -> Bool
    intersecting i ds  = DateSet.intersects ds i
intersecting (Intersection subsets) i = all (intersecting i) subsets
  where
    intersecting :: Interval -> DateSet -> Bool
    intersecting i ds = DateSet.intersects ds i

-- | Returns the smallest interval which contains the entire set.
span :: DateSet -> Interval
span _ = error "NotImplemented"

-- | A hint to the scheduler about the smallest time scales within the set.
resolution :: DateSet -> Interval
resolution _ = error "NotImplemented"

-- | True if the given dt is part of this set.
within :: DateSet -> DateTime -> Bool
within self dt = Interval.within (largestIntervalContaining self) dt

-- | True if the given window is completely contained by this set.
contains :: DateSet -> Interval -> Bool
contains _ = error "NotImplemented"

-- | Return an ordered sequence of intervals which intersect `window`.
--
-- If window is not given, and dateset is finite, then yields every
-- interval in the date set.
--
-- If this window is not given, and the dateset is not finite, this
-- will raise `ValueError'.
intervals :: DateSet -> Maybe Interval -> [Interval]
intervals _ = error "NotImplemented"

-- | Yield tuples of `(intervals, completed)`.
--
-- A single timestamp within an interval is considered a "completion
-- event", which discharges the obligation implied by the interval.
--
-- Multiple timestamps within an interval are ignored, as are
-- timestamps outside of a completion window.
--
-- `window` is treated the same as in `intervals`.
completions :: DateSet -> [DateTime] -> Maybe Interval -> [(Interval, Bool)]
completions self history window = completed <$> intervals self window
  where
    completed i = (i, any (Interval.within i) history)

-- | True if all intervals within the window have a completion event.
--
-- If `window` is `Nothing`, then:
--   - if self is finite     -- all intervals in dateset must be complete.
--   - else                  -- returns False
isComplete :: DateSet -> [DateTime] -> Maybe Interval -> Bool
isComplete self history window = case window of
  Nothing -> if Interval.finite (DateSet.span self)
             then go Nothing
             else False
  window -> go window
  where
    go window = all snd $ completions self history window

-- | Find the largest interval within the dateset that contains the given time.
largestIntervalContaining :: DateSet -> Interval
largestIntervalContaining _ = error "NotImplemented"

-- | Return the inverse of the given date set.
invert :: DateSet -> DateSet
invert _ = error "Not implemented"
