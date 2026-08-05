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
  parseDay,
  parseMonth,
  parseTimeOfDay,
  parseISODate,
  parseDateTime,
  parseTimePeriod,
  parseDuration
) where

import Control.Monad
--import Data.Set ()
--import qualified Data.Set as Set

import Data.Time.Clock
import Data.Time.Calendar.OrdinalDate
import Data.Time.Calendar
import Data.Time.Format.ISO8601
import Data.Time.LocalTime
import Text.Parse

-- import Util
import Interval ({-Interval(..),-} DateTime, TimeDelta, TimePeriod(..), (|+))
import qualified Interval as Interval
-- import DateSet

-- | Parse a string into a timedelta, using our custom notation.
parseDuration :: TextParser TimeDelta
parseDuration = do
  quant <- parseSigned parseDec
  unit  <- oneOf (literal <$> ["w", "d", "h", "m", "s"])
  let q = fromInteger quant
  case unit of
    "d"   -> return $ q * Interval.day
    "h"   -> return $ q * Interval.hour
    "m"   -> return $ q * Interval.minute
    "w"   -> return $ q * Interval.week
    _     -> failBad "Invalid Unit"

parseTimeOfDay :: TextParser TimeOfDay
parseTimeOfDay =
  do
    time <- sepBy1 (parseSigned parseDec) (literal ":")
    case time of
      [h] -> tod h 0 0
      [h, m] -> tod h m 0
      [h, m, s] -> tod h m s
      _ -> fail $ "Invalid date format"
  where
    tod :: Int -> Int -> Int -> TextParser TimeOfDay
    tod h m s = do
      unless ((0 <= h) && (h <= 23)) $ failBad $ "Hour out of range: " ++ show h
      unless ((0 <= m) && (m <= 59)) $ failBad $ "Min out of range: " ++ show m
      unless ((0 <= s) && (s <= 60)) $ failBad $ "Seconds out of range: " ++ show s
      return $ TimeOfDay h m (fromIntegral s)

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
    err   -> fail $ "Invalid month: " ++ err

parseISODate :: TextParser Day
parseISODate = do
  year <- parseDec
  _ <- literal "-"
  month <- parseDec
  _ <- literal "-"
  day <- parseDec
  case fromGregorianValid year month day of
    Nothing -> failBad $ "invalid date: " ++ show (year, month, day)
    Just d  -> return d

parseDateTime :: TextParser DateTime
parseDateTime = do
  date <- parseISODate
  time <- onFail tryParseTime (return midnight)
  return $ UTCTime date (timeOfDayToTime time)
    where
      tryParseTime = do
        _ <- literal "T"
        time <- parseTimeOfDay
        _ <- optional $ literal "Z"
        return time

parseXY :: TextParser a -> TextParser b -> TextParser (Either a b)
parseXY x y = onFail (Left <$> x) (Right <$> y)

parseTimePeriod :: TextParser TimePeriod
parseTimePeriod = do
  start <- parseDateTime
  _ <- many1 $ literal " "
  next <- parseXY parseDateTime parseDuration
  case next of
    Left  end -> return $ TimePeriod start end
    Right dur -> return $ TimePeriod start $ start |+ dur

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
