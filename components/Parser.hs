{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}

-- | Parser for custom DSL for datetime recurrence expressions.
--
-- We use Text.Parse from Polyparse, because that's what graphviz uses.
--
-- XXX: This is a work in progress, containing only the bits that are
-- re-used on the JSON side. Would love to geek out on this right now,
-- but compat is more important.
module Parser (
  parseDuration,
  parseDay,
  parseMonth
) where

import Data.Set (Set)
import qualified Data.Set as Set
import Data.Time.Clock
import Data.Time.Calendar.OrdinalDate
import Data.Time.Calendar
import Data.Time.Format.ISO8601
import Data.Time.LocalTime
import Text.Parse

import Util
import Interval (Interval, DateTime, TimeDelta)
import qualified Interval as Interval
import DateSet

-- | Parse a string into a timedelta, using our custom notation.
parseDuration :: TextParser TimeDelta
parseDuration = do
  quant <- parseDec
  unit  <- oneOf (literal <$> ["w", "d", "h", "m", "s"])
  case unit of
    "d" -> return $ (fromInteger quant) * Interval.day
    "h" -> return $ (fromInteger quant) * Interval.hour
    "m" -> return $ (fromInteger quant) * Interval.second
    "w" -> return $ (fromInteger quant) * Interval.week
    _   -> failBad "Invalid Unit"

-- | Parse a day abbreviation into a DayOfWeek value.
parseDay :: TextParser DayOfWeek
parseDay = do
  possible <- word
  case possible of
    "mon" -> return Monday
    "tue" -> return Tuesday
    "wed" -> return Wednesday
    "thu" -> return Thursday
    "fri" -> return Friday
    "sat" -> return Saturday
    "sun" -> return Sunday
    _     -> failBad "Invalid day of week"

-- | Parse a month abbreviation from a string.
parseMonth :: TextParser MonthOfYear
parseMonth = do
  possible <- word
  case possible of
    "jan" -> return January
    "feb" -> return February
    "mar" -> return March
    "apr" -> return April
    "may" -> return May
    "jun" -> return June
    "jul" -> return July
    "aug" -> return August
    "sep" -> return September
    "oct" -> return October
    "nov" -> return November
    "dec" -> return December

-- This one needs some work.
{-
parseDays :: TextParser DateSet
parseDays = oneOf [dayRange, dayList]
  where
    dayRange = do
      start <- parseDay
      oneOf [literal "-", literal "to"]
      end <- parseDay
      return $ Explicit $ Set.fromList [start .. end]

    dayList = do
      days <- sepBy1 parseDay (literal ",")
      return $ Explicit $ Set.fromList days
-}
