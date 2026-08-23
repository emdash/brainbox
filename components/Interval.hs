{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}

module Interval (
  AddDT,
  (|+),
  (|-),
  (|-|),
  Interval(..),
  DateTime,
  TimeDelta,
  IWithin(..),
  TimePeriod(..),
  toInterval,
  fromInterval,
  Interval.span,
  second,
  minute,
  hour,
  day,
  week,
  now,
  fromDay,
  startOfDay,
  endOfDay,
  startOfAgendaDay,
  endOfAgendaDay,
  weekday,
  nextMonth,
  prevMonth,
  startOfWeek,
  endOfWeek,
  startOfMonth,
  endOfMonth,
  dayOfMonth,
  monthOfYear,
  dayOfWeek,
  today,
  yesterday,
  tomorrow,
  origin,
  duration,
  contains,
  intersects,
  intersection,
  invert,
  fromStartDuration,
  fromDate,
  fromDate',
  ordinals,
  finite,
  Interval.sequence,
  mergeConsecutive,
  sequenceWeeks,
  sequenceMonths,
  sequenceTime
) where


import Prelude hiding (sequence)

import Data.Time.Clock
import Data.Time.Calendar
import Data.Time.Calendar.Month
import Data.Time.Calendar.OrdinalDate
import Data.Time.Calendar.WeekDate
import Data.Tuple.Utils

import Util

-------------------------------------------------------------------------------

type DateTime = UTCTime
type TimeDelta = NominalDiffTime

weekday :: DateTime -> DayOfWeek
weekday (UTCTime day _) = dayOfWeek day

dayOfMonth :: DateTime -> DayOfMonth
dayOfMonth (UTCTime day _) = thd3 $ toGregorian day

monthOfYear :: DateTime -> MonthOfYear
monthOfYear (UTCTime day _) = snd3 $ toGregorian day

infixl 6 |+
infixl 6 |-
infixl 6 |-|

class AddDT a where
  (|+) :: a -> TimeDelta -> a
  (|-) :: a -> TimeDelta -> a
  (|-) x dt = x |+ (-dt)

instance AddDT DateTime where
  (|+) x y = addUTCTime y x

(|-|) :: DateTime -> DateTime -> TimeDelta
(|-|) x y = diffUTCTime x y

second :: TimeDelta
second = secondsToNominalDiffTime 1

minute :: TimeDelta
minute = second * 60

hour :: TimeDelta
hour = minute * 60

day :: TimeDelta
day = nominalDay

week :: TimeDelta
week = day * 7

now :: IO DateTime
now = getCurrentTime

fromDay :: Day -> DateTime
fromDay d = UTCTime d (fromInteger 0)

startOfDay :: DateTime -> DateTime
startOfDay (UTCTime day _) = fromDay day

endOfDay :: DateTime -> DateTime
endOfDay day = startOfDay day |+ nominalDay

startOfAgendaDay :: DateTime -> DateTime
startOfAgendaDay (UTCTime day _) = fromDay day |+ 8 * hour

endOfAgendaDay :: DateTime -> DateTime
endOfAgendaDay (UTCTime day _) = fromDay day |+ 23 * hour

today :: IO DateTime
today = startOfDay <$> now

yesterday :: IO DateTime
yesterday = do
  td <- today
  pure $ td |- day

tomorrow :: IO DateTime
tomorrow = do
  td <- today
  pure $ td |+ day

origin :: DateTime
origin =  UTCTime (fromOrdinalDate 1 1) 0

prevMonth :: DateTime -> DateTime
prevMonth (UTCTime day time) =
  let (y, m, d) = toGregorian day
  in case pred m of
    December -> UTCTime (fromGregorian (pred y) December d) time
    m        -> UTCTime (fromGregorian y m d) time

nextMonth :: DateTime -> DateTime
nextMonth (UTCTime day time) =
  let (y, m, d) = toGregorian day
  in case succ m of
    January -> UTCTime (fromGregorian (succ y) January d) time
    m       -> UTCTime (fromGregorian y m d) time

startOfWeek :: DateTime -> DateTime
startOfWeek (UTCTime day _) =
  let (y, w, _) = toWeekDate day
  in (UTCTime (fromWeekDate y w 0) (fromInteger 0))

endOfWeek :: DateTime -> DateTime
endOfWeek (UTCTime day _ ) =
  let (y, w, _) = toWeekDate day
  in UTCTime (fromWeekDate y (w + 1) 0) (fromInteger 0)

startOfMonth :: DateTime -> DateTime
startOfMonth (UTCTime day _) =
  let (y, m, d) = toGregorian day
  in UTCTime (fromGregorian y m 1) (fromInteger 0)

endOfMonth :: DateTime -> DateTime
endOfMonth (UTCTime day _) =
  let (y, m, _) = toGregorian day
      month     = YearMonth y m
  in UTCTime (periodFirstDay (succ month)) (fromInteger 0) |- second

-- These terms differ from their common mathematical meaning, but they
-- make sense to me. Stick with these for the ease of porting from
-- python, then rename once it's all working correctly.
--
-- Open  => Infinite
-- LeftOpen => UpperBounded
-- RightOpen => LowerBounded
-- Closed => Finite

class IWithin a where
  within :: a -> DateTime -> Bool

-------------------------------------------------------------------------------

-- | A closed interval
data TimePeriod = TimePeriod DateTime DateTime deriving (Eq, Ord, Show)

instance IWithin TimePeriod where
  within (TimePeriod s e) x = between s x e

toInterval :: TimePeriod -> Interval
toInterval (TimePeriod s e) = Closed s e

fromInterval :: Interval -> Maybe TimePeriod
fromInterval (Closed s e) = Just $ TimePeriod s e
fromInterval _            = Nothing

sequence
  :: DateTime
  -> DateTime
  -> TimeDelta
  -> [DateTime]
sequence i end dur
  | i <= end = i : sequence (i |+ dur) end dur
sequence _ _ _ = []

-------------------------------------------------------------------------------

-- | The time between two timestamps, or a start timestamp and duration.
data Interval
  = Empty
  | Open
  | LeftOpen DateTime
  | RightOpen DateTime
  | Closed DateTime DateTime
  deriving (Ord, Eq, Show)

instance IWithin Interval where
-- | True if the given timestamp falls within self.
  within Empty             _  = False
  within Open              _  = True
  within (LeftOpen  end)   dt = dt <= end
  within (RightOpen start) dt = start <= dt
  within (Closed    s e)   dt = between s dt e

-- | The smallest interval containing both self and i
span :: Interval -> Interval -> Interval
span Empty         i              = i
span Open          _              = Open
span left          Empty          = left
span _             Open           = Open
span (LeftOpen e)  (LeftOpen e')  = LeftOpen  $ max e e'
span (LeftOpen _ ) (RightOpen _)  = Open
span (LeftOpen e)  (Closed _ e')  = LeftOpen  $ max e e'
span (RightOpen _) (LeftOpen _)   = Open
span (RightOpen s) (RightOpen s') = RightOpen $ min s s'
span (RightOpen s) (Closed s' _)  = RightOpen $ min s s'
span (Closed _ e)  (LeftOpen e')  = LeftOpen  $ max e e'
span (Closed s _)  (RightOpen s') = RightOpen $ min s s'
span (Closed s e)  (Closed s' e') = Closed (min s s') (max e e')


duration :: Interval -> Maybe TimeDelta
duration Empty           = Just $ fromInteger 0
duration Open            = Nothing
duration (LeftOpen  _)   = Nothing
duration (RightOpen _)   = Nothing
duration (Closed    l u) = Just $ l |-| u

-- | True if the right interval is completely contained within the left.
contains :: Interval -> Interval -> Bool
contains Empty         _              = False
contains Open          _              = True
contains _             Empty          = False
contains _             Open           = True
contains (LeftOpen e)  (LeftOpen e')  = e >= e'
contains (LeftOpen _)  (RightOpen _)  = False
contains (LeftOpen e)  (Closed _ e')  = e' <= e
contains (RightOpen _) (LeftOpen _)   = False
contains (RightOpen s) (RightOpen s') = s <= s'
contains (RightOpen s) (Closed s' _)  = s >= s'
contains (Closed _ _)  (LeftOpen _)   = False
contains (Closed _ _)  (RightOpen _)  = False
contains s@(Closed _ _) (Closed s' e) = within s s' && within s e

-- | True if the right interval touches or is partially contained within the right.
intersects :: Interval -> Interval -> Bool
intersects left right = case intersection left right of
  Empty -> False
  _     -> True

intersection :: Interval -> Interval -> Interval
intersection Empty         _             = Empty
intersection Open          right         = right
intersection _             Empty         = Empty
intersection left          Open          = left
intersection (LeftOpen e)  (LeftOpen e') = LeftOpen $ min e e'
intersection (LeftOpen e)  (RightOpen s) =
  if s <= e
  then Closed s e
  else Empty
intersection l@(LeftOpen e) r@(Closed s e') =
  if within r e || within l s
  then Closed s $ min e e'
  else Empty
intersection   (RightOpen s)   (LeftOpen e) =
  if s <= e
  then Closed s e
  else Empty
intersection (RightOpen s) (RightOpen s') =
  RightOpen $ max s s'
intersection l@(RightOpen s) r@(Closed s' e) =
  if within r s || within l e
  then Closed (max s s') e
  else Empty
intersection l@(Closed s e) r@(LeftOpen e') =
  if within l e' || within r s
  then Closed s $ min e e'
  else Empty
intersection l@(Closed s e) r@(RightOpen s')  =
  if within l s' || within r s
  then Closed (max s s') e
  else Empty
intersection l@(Closed s e) r@(Closed s' e') =
  if   within l s'
    || within l e'
    || within r s
    || within r e
  then Closed (max s s') (min e e')
  else Empty

invert :: Interval -> Either Interval (Interval, Interval)
invert Empty         = Left Open
invert Open          = Left Empty
invert (LeftOpen e)  = Left $ RightOpen e
invert (RightOpen s) = Left $ LeftOpen s
invert (Closed s e)  = Right (LeftOpen s, RightOpen e)

instance AddDT Interval where
  (|+) Empty         _  = Empty
  (|+) Open          _  = Empty
  (|+) (LeftOpen  e) dt = LeftOpen $ e |+ dt
  (|+) (RightOpen s) dt = LeftOpen $ s |+ dt
  (|+) (Closed s e)  dt = Closed (s |+ dt) (e |+ dt)

fromStartDuration :: DateTime -> TimeDelta -> Interval
fromStartDuration s d = Closed s (s |+ d)

fromDate :: DateTime -> Maybe DateTime -> Interval
fromDate dt (Just end) = Closed (startOfDay dt) (startOfDay $ end |+ day)
fromDate dt Nothing    = Closed (startOfDay dt) (startOfDay $ dt  |+ day)

fromDate' :: DateTime -> Interval
fromDate' dt = fromDate dt Nothing

ordinals :: Interval -> [Day]
ordinals Empty = []
ordinals Open  = error "Infinite"
ordinals (LeftOpen (UTCTime day _)) = go day
  where go d = d : (go $ addDays (-1) d)
ordinals (RightOpen (UTCTime day _)) = go day
  where go d = d : (go $ addDays 1 d)
ordinals (Closed (UTCTime start _) (UTCTime end _)) = go start
  where
    go d =
      if d > end
      then []
      else d : (go $ addDays 1 d)

finite :: Interval -> Bool
finite Empty = True
finite (Closed _ _) = True
finite _ = False

-- | Assuming the input is sorted, merges runs of interstecting
-- intervals into a single interval.
mergeConsecutive :: [Interval] -> [Interval]
mergeConsecutive [] = []
mergeConsecutive (x : xs) = go x xs
  where
    go next [] = [next]
    go next (i : rest) =
      if intersects next i
      then go (Interval.span next i) rest
      else case next of
        Empty -> go i rest
        Open  -> [Open]
        RightOpen _ -> [next]
        _     -> next : (go i rest)

sequenceMonths :: TimePeriod -> [Month]
sequenceMonths (TimePeriod (UTCTime s _) (UTCTime e _)) = go start
  where
    start = let (y, m, _) = toGregorian s in YearMonth y m
    end   = let (y, m, _) = toGregorian e in YearMonth y m
    go m  =
      if m <= end
      then m : (go (succ m))
      else []

sequenceWeeks :: TimePeriod -> [[Day]]
sequenceWeeks (TimePeriod (UTCTime s _) (UTCTime e _)) = go $ weekFirstDay Sunday s
  where
    go d | d <= e = (weekAllDays Sunday d) : go (addDays 7 d)
    go _ = []

sequenceTime :: TimeDelta -> TimeDelta -> TimeDelta -> [TimeDelta]
sequenceTime i end step | i < end = i : sequenceTime (i + step) end step
sequenceTime _ _ _ = []
