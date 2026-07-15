{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}

module Brainbox.Scheduler where

import Data.Ratio
import Text.JSON
import Data.Maybe
import Data.Map (Map)
import qualified Data.Map as Map
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
import qualified JSONParser as JP


main :: IO ()
main = error "not implemented"
