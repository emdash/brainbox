{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}

module DateSet (
  DateSet(..),
  finite,
  intersects,
  DateSet.span,
  within,
  contains,
  intervals,
  completions,
  isComplete,
  largestIntervalContaining,
  invert
) where

import Control.Monad
import Data.Fixed
import Data.Foldable
import qualified Data.List
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe
import Data.Set (Set)
import qualified Data.Set as Set

import Data.Time.Clock
import Data.Time.Calendar.OrdinalDate
import Data.Time.Calendar
import Data.Time.Format.ISO8601
import Data.Time.LocalTime

import Util
import Interval (Interval(..), DateTime, TimeDelta, (|+), (|-), (|-|))
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
  | Weekly {which :: Set DayOfWeek}
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
span (Explicit intervals)   = foldl Interval.span Empty intervals
span (Union subsets)        = foldl unSpan  Empty subsets
span (Intersection subsets) = foldl intSpan Open  subsets
span (Periodic _ _ _)       = Open
span (AtTime _ _ _)         = Open
span (Weekly _ )            = Open
span (Monthly _)            = Open
span (NthWeekday _ _ _)     = Open
span (Shift offset subset)  = (DateSet.span subset) |+ offset

-- | helper for computing the span of an intersection via fold
unSpan :: Interval -> DateSet -> Interval
unSpan ret s = Interval.span (DateSet.span s) ret

-- | helper for computing the span of an intersection via fold
intSpan :: Interval -> DateSet -> Interval
intSpan ret s = case DateSet.span s of
  Empty -> Empty
  Open  -> ret
  i     -> Interval.intersection ret i

-- | True if the given dt is part of this set.
within :: DateSet -> DateTime -> Bool
within self dt = Interval.within (largestIntervalContaining self dt) dt

implicitContains :: DateSet -> Interval -> Bool
intersecting

-- | True if the given window is completely contained by this set.
contains :: DateSet -> Interval -> Bool
contains (Explicit intervals)   w = any (Interval.contains -$ w) intervals
contains (Union subsets)        w = any (DateSet.contains  -$ w)  subsets
contains (Intersection subsets) w = all (DateSet.contains  -$ w)  subsets
contains (Periodic _ _ _)       w = undefined
contains (AtTime _ _ _)         w = undefined
contains (Weekly _ )            w = undefined
contains (Monthly _)            w = undefined
contains (NthWeekday _ _ _)     w = undefined
contains (Shift offset subset)  w = undefined


implicitIntervals :: DateSet -> Interval -> [Interval]
implicitIntervals self window =
  Interval.mergeConsecutive
  $ filter (DateSet.contains self)
  $ Interval.sequence window Interval.minute Nothing Nothing

-- | Return an ordered sequence of intervals which intersect `window`.
--
-- If window is not given, and dateset is finite, then yields every
-- interval in the date set.
--
-- If this window is not given, and the dateset is not finite, this
-- will raise `ValueError'.
intervals :: DateSet -> Maybe Interval -> [Interval]
intervals (Explicit intervals) Nothing = Interval.mergeConsecutive
  $ Set.toAscList intervals
intervals (Explicit intervals) (Just w) = filter
    (Interval.intersects w)
  $ Interval.mergeConsecutive
  $ Set.toAscList intervals
intervals self (Just w) = implicitIntervals self w

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
largestIntervalContaining :: DateSet -> DateTime -> Interval
largestIntervalContaining = lic

firstWeekday :: DayOfWeek -> MonthOfYear -> Year -> Day
firstWeekday = undefined

lastWeekday :: DayOfWeek -> MonthOfYear -> Year -> Day
lastWeekday = undefined

nthWeekday :: Integer -> DayOfWeek -> MonthOfYear -> Year -> Day
nthWeekday n weekday month year
  | n > 0 =  ((n - 1) * 7) `addDays` (firstWeekday weekday month year)
  | n < 0 = (((abs n) - 1) * 7) `addDays` (lastWeekday  weekday month year)
nthWeekday _ _ _ _ = error "N cannot be 0"

lic :: DateSet -> DateTime -> Interval
lic (Explicit intervals)   dt = fromMaybe Empty $ find (Interval.within -$ dt) intervals
lic (Union subsets)        dt = foldl Interval.span Empty $ (lic -$ dt) <$> subsets
-- xxx: probably wrong
lic (Intersection subsets) dt = foldl go Open $ subsets
  where
    go acc i = Interval.intersection acc (lic i dt)
lic (Periodic period duration phase) dt =
  let as_delta = dt |-| Interval.origin
      start    = Interval.origin |+ (as_delta - ((as_delta - phase) `mod'` period))
      end      = start |+ duration
  in if between start dt end
     then Closed start end
     else Empty
lic (AtTime start duration inverted) dt =
  let start = UTCTime dt.utctDay start.utctDayTime
      end   = start |+ duration
      sod   = Interval.startOfDay dt
      eod   = Interval.endOfDay   dt
  in if inverted
     then handleInverted start end sod eod
     else if between start dt end
       then Closed start end
       else Empty
  where
    handleInverted start end sod eod
      | between sod dt start = Closed sod start
      | between end dt eod   = Closed end eod
    handleInverted _ _ _ _   = Empty
lic (Weekly days) dt =
  if Set.member (dayOfWeek dt.utctDay) days
  then Interval.fromDate dt Nothing
  else Empty
lic (Monthly months) dt =
  let (year, month, day) = toGregorian (utctDay dt)
      days               = fromMaybe Set.empty $ Map.lookup month months
      intervals          = Interval.mergeConsecutive $
            Interval.fromDate -$ Nothing
        <$> UTCTime -$ (fromInteger 0)
        <$> fromGregorian year month
        <$> Set.toAscList days
  in fromMaybe Empty $ find (Interval.within -$ dt) intervals
lic (NthWeekday n wd m) dt@(UTCTime d _) =
  if dayOfWeek d == wd
  then
    let
      (year, month, day) = toGregorian d
      month' = fromMaybe month m
      nd = nthWeekday (toInteger n) wd month' year
    in if d == nd
       then Interval.fromDate dt Nothing
       else Empty
  else Empty
lic (Shift offset subset)  dt = (lic subset (dt |- offset)) |+ offset

-- | Return the inverse of the given date set.
invert :: DateSet -> DateSet
invert _ = error "Not implemented"
