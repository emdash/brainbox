#! /usr/bin/env python

"""Test of calendar functions"""

from schedule import *
import sys
from datetime import *

def test_superordinal():
  assert superordinal(datetime(2025, 12, 17)) == 63901612800
  assert superordinal(1 * day) == 86400

def test_first_of_month():
  for month in range(1, 13):
    assert firstOfMonth(month, 2025) == datetime(2025, month, 1)
    assert firstOfMonth(month, 2024) == datetime(2024, month, 1)
    assert firstOfMonth(month, 2000) == datetime(2000, month, 1)

def test_start_of_week():
  for year in range(2000, 2025):
    for month in range(1, 12):
      for day in range(1, 28):
        assert startOfWeek(day, month, year).weekday() == 0

def test_days_of_month():
  assert len(list(daysOfMonth(2025, 1))) == 31
  assert len(list(daysOfMonth(2025,11))) == 30
  assert len(list(daysOfMonth(2025, 4))) == 30
  assert len(list(daysOfMonth(2025, 2))) == 28
  assert len(list(daysOfMonth(2024, 2))) == 29
  assert len(list(daysOfMonth(2000, 2))) == 29
  assert len(list(daysOfMonth(1900, 2))) == 28

def test_start_of_day():
  for d in (today, today + 5 * day, today - 20 * day):
    assert startOfDay(d).hour   == 0
    assert startOfDay(d).minute == 0
    assert startOfDay(d).second == 0

def test_end_of_day():
  for d in (today, today + 5 * day, today - 20 * day):
    assert endOfDay(d).hour   == 23
    assert endOfDay(d).minute == 59
    assert endOfDay(d).second == 59
    assert endOfDay(d).microsecond == 999_999

def test_nth_weekday():
  try:
    nthWeekday(0, 0, 11, 2025) == datetime(2025, 11, 3)
    assert "Should not Get Here"
  except ValueError as e:
    assert e.args[0] == "`n` cannot be 0"

  assert nthWeekday(1, 0, 11, 2025) == datetime(2025, 11, 3)
  assert nthWeekday(1, 5, 11, 2025) == datetime(2025, 11, 1)
  assert nthWeekday(1, 6, 11, 2025) == datetime(2025, 11, 2)
  assert nthWeekday(4, 3, 11, 2025) == datetime(2025, 11, 27)
  assert nthWeekday(3, 2,  7, 2025) == datetime(2025, 7, 16)

  assert nthWeekday(-1, 4, 10, 2025) == datetime(2025, 10, 31)
  assert nthWeekday(-1, 4,  8, 2025) == datetime(2025,  8, 29)
  assert nthWeekday(-1, 4,  9, 2025) == datetime(2025,  9, 26)
  assert nthWeekday(-2, 5, 12, 2025) == datetime(2025, 12, 20)


def test_intervals():
  i1 = Interval.fromStartDuration(now,             3 * day)
  i2 = Interval.fromStartDuration(yesterday,       3 * day)
  i3 = Interval.fromStartDuration(tomorrow,        3 * day)
  i4 = Interval.fromStartDuration(today - 3 * day, 1 * day)

  assert not i1.within(now + 3 * day)
  assert     i1.within(now + 3 * day - 1 * minute)
  assert     i1.within(now + 1 * day)
  assert     i1.within(tomorrow)
  assert not i1.within(now - 1 * minute)
  assert not i1.within(now + 3 * day + 1 * minute)

  for i in [i2, i3]:
    assert i1.intersects(i)
  assert not i1.intersects(i4)

  # assert     i1.contains(Interval(now + 1 * minute, now + 3 * day - 1 * minute))
  # assert not Interval(now + 1 * minute, now + 3 * day - 1 * minute).contains(i)

  assert list(Interval(today, tomorrow).subdivide(4 * hour)) == [
    Interval(today            , today +  4 * hour),
    Interval(today +  4 * hour, today +  8 * hour),
    Interval(today +  8 * hour, today + 12 * hour),
    Interval(today + 12 * hour, today + 16 * hour),
    Interval(today + 16 * hour, today + 20 * hour),
    Interval(today + 20 * hour, tomorrow),
  ]

def test_periodic():
  p = Periodic(4 * hour, 10 * minute, 0 * minute)
  step = 1 * hour
  for i in range(1 * day // step):
    x = today + i * step
    if p.intersects(Interval(x, x + step)):
      print('|', end='')
    else:
      print('.', end='')
  print()

def test_display_month():
  pass

def test_interval_sequence():
  pass

def test_interval_merge_consecutive():
  pass

def test_interval_within():
  pass

def test_interval_intersects():
  pass

def test_interval_span():
  pass

def test_interval_intersection():
  pass

def test_interval_ordinals():
  pass

def test_explicit():
  pass

def test_union():
  pass

def test_intersection():
  pass

def test_periodic():
  pass

def test_at_time():
  pass

def test_daily():
  pass

def test_weekly():
  pass

def test_monthly():
  pass

def test_nth_weekday_set():
  pass

def test_parse_pattern():
  pass

def main(*args):
  self = __import__(__name__)
  match args:
    case []|["all"]:
      for test in sorted(dir(self)):
        if test.startswith('test_'):
          getattr(self, test)()
    case [test]:
      getattr(self, test)()
    case invalid: raise ValueError(f"Invalid Command: {" ".join(invalid)}")

if __name__ == "__main__":
  main(*sys.argv[1:])
