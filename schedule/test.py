#! /usr/bin/env python

"""Test of calendar functions"""

from datetime import *
import json
from schedule import *
import sys

from itertools import islice

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

  assert list(Interval(today, tomorrow).subdivide(4 * hour)) == [
    Interval(today            , today +  4 * hour),
    Interval(today +  4 * hour, today +  8 * hour),
    Interval(today +  8 * hour, today + 12 * hour),
    Interval(today + 12 * hour, today + 16 * hour),
    Interval(today + 16 * hour, today + 20 * hour),
    Interval(today + 20 * hour, tomorrow),
  ]

def test_display_month():
  pass

def test_interval_sequence():
  assert list(islice(Interval.sequence(
    datetime(2025, 11, 10),
    5 * minute
  ), 0, 3)) == [
    Interval.fromStartDuration(datetime(2025, 11, 10),        5 * minute),
    Interval.fromStartDuration(datetime(2025, 11, 10, 0, 5),  5 * minute),
    Interval.fromStartDuration(datetime(2025, 11, 10, 0, 10), 5 * minute)
  ]

  assert list(islice(Interval.sequence(
    datetime(2025, 11, 10),
    5 * minute,
    1 * hour
  ), 0, 3)) == [
    Interval.fromStartDuration(datetime(2025, 11, 10, 0, 0), 5 * minute),
    Interval.fromStartDuration(datetime(2025, 11, 10, 1, 0), 5 * minute),
    Interval.fromStartDuration(datetime(2025, 11, 10, 2, 0), 5 * minute)
  ]

  assert list(islice(Interval.sequence(
    datetime(2025, 11, 10),
    5 * minute,
    1 * hour,
    2 * minute
  ), 0, 3)) == [
    Interval.fromStartDuration(datetime(2025, 11, 10, 0, 2), 5 * minute),
    Interval.fromStartDuration(datetime(2025, 11, 10, 1, 2), 5 * minute),
    Interval.fromStartDuration(datetime(2025, 11, 10, 2, 2), 5 * minute)
  ]


def test_interval_merge_consecutive():
  assert list(Interval.mergeConsecutive([
    Interval(datetime(2025, 11, 10, 14, 30), datetime(2025, 11, 10, 15, 00))
  ])) == [
    Interval(datetime(2025, 11, 10, 14, 30), datetime(2025, 11, 10, 15, 00))
  ]

  assert list(Interval.mergeConsecutive([
    Interval(datetime(2025, 11, 10, 14, 30), datetime(2025, 11, 10, 15)),
    Interval(datetime(2025, 11, 10, 15, 00), datetime(2025, 11, 10, 16)),
    Interval(datetime(2025, 11, 10, 16, 00), datetime(2025, 11, 10, 19, 39))
  ])) == [Interval(datetime(2025, 11, 10, 14, 30), datetime(2025, 11, 10, 19,  39))]

  assert list(Interval.mergeConsecutive([
    Interval(datetime(2025, 11, 10, 14, 30), datetime(2025, 11, 10, 14, 45)),
    Interval(datetime(2025, 11, 10, 15, 00), datetime(2025, 11, 10, 16, 1)),
    Interval(datetime(2025, 11, 10, 16, 00), datetime(2025, 11, 10, 19, 39))
  ])) == [
    Interval(datetime(2025, 11, 10, 14, 30), datetime(2025, 11, 10, 14,  45)),
    Interval(datetime(2025, 11, 10, 15, 00), datetime(2025, 11, 10, 19,  39)),
  ]

def test_interval_within():
  assert Interval(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).within(datetime(2025, 10, 11, 12, 30)) == True

  assert Interval(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).within(datetime(2025, 10, 12, 0, 0)) == False

  assert Interval(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).within(datetime(2025, 10, 12, 23, 59, 59, 999999)) == False

  assert Interval(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).within(datetime(2025, 10, 10, 23, 59, 59, 999999)) == False

  assert Interval(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).within(datetime(2025, 10, 9, 9, 30)) == False


def test_interval_intersects():
  assert Interval(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).intersects(Interval(
    datetime(2025, 10, 11, 12, 30),
    datetime(2025, 10, 11, 13, 00)
  )) == True

  assert Interval(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).intersects(Interval(
    datetime(2025, 10, 10, 23, 30),
    datetime(2025, 10, 10, 23, 59, 59, 999999)
  )) == False

  assert Interval(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).intersects(Interval(
    datetime(2025, 10, 10, 23, 30),
    datetime(2025, 10, 11)
  )) == True

  assert Interval(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).intersects(Interval(
    datetime(2025, 10, 12),
    datetime(2025, 10, 13)
  )) == True

def test_interval_span():
  assert Interval(
    datetime(2025, 10, 11, 16, 00),
    datetime(2025, 10, 11, 16, 30)
  ).span(Interval(
    datetime(2025, 10, 11, 16, 45),
    datetime(2025, 10, 11, 17, 20)
  )) == Interval(
    datetime(2025, 10, 11, 16, 00),
    datetime(2025, 10, 11, 17, 20)
  )

def test_interval_intersection():
  assert Interval(
    datetime(2025, 10, 11, 16, 00),
    datetime(2025, 10, 11, 16, 45)
  ).intersection(Interval(
    datetime(2025, 10, 11, 16, 30),
    datetime(2025, 10, 11, 17, 20)
  )) == Interval(
    datetime(2025, 10, 11, 16, 30),
    datetime(2025, 10, 11, 16, 45)
  )

def test_interval_ordinals():
  assert list(Interval(
    datetime(2025, 10, 11, 16, 30),
    datetime(2025, 10, 11, 17, 30)
  ).ordinals()) == [739535]

  assert list(Interval(
    datetime(2025, 10, 11, 16, 30),
    datetime(2025, 10, 12, 17, 30)
  ).ordinals()) == [739535, 739536]

def test_explicit():
  # no overlap
  assert list(Explicit([
    Interval(
      datetime(2025, 10, 11, 16, 00),
      datetime(2025, 10, 11, 16, 30)
    ), Interval(
      datetime(2025, 10, 11, 16, 45),
      datetime(2025, 10, 11, 17, 20)
    ), Interval(
      datetime(2025, 10, 11, 17, 35),
      datetime(2025, 10, 11, 17, 47)
    )
  ]).intervals(Interval(
      datetime(2025, 10, 10, 16, 00),
      datetime(2025, 10, 13, 16, 30),
  ))) == [
    Interval(
      datetime(2025, 10, 11, 16, 00),
      datetime(2025, 10, 11, 16, 30)
    ), Interval(
      datetime(2025, 10, 11, 16, 45),
      datetime(2025, 10, 11, 17, 20)
    ), Interval(
      datetime(2025, 10, 11, 17, 35),
      datetime(2025, 10, 11, 17, 47)
    )
  ]

  # no overlap
  assert list(Explicit([
    Interval(
      datetime(2025, 10, 11, 16, 00),
      datetime(2025, 10, 11, 16, 30)
    ), Interval(
      datetime(2025, 10, 11, 16, 45),
      datetime(2025, 10, 11, 17, 20)
    ), Interval(
      datetime(2025, 10, 11, 17, 15),
      datetime(2025, 10, 11, 17, 47)
    )
  ]).intervals(Interval(
      datetime(2025, 10, 10, 16, 00),
      datetime(2025, 10, 13, 16, 30),
  ))) == [
    Interval(
      datetime(2025, 10, 11, 16, 00),
      datetime(2025, 10, 11, 16, 30)
    ), Interval(
      datetime(2025, 10, 11, 16, 45),
      datetime(2025, 10, 11, 17, 47)
    )
  ]

def test_periodic():
  assert list(Periodic(
    4 * hour,
    15 * minute,
  ).intervals(Interval.fromDate(datetime(2025, 10, 11)))
  ) == [
    Interval(start=datetime(2025, 10, 11, 0, 0), end=datetime(2025, 10, 11, 0, 15)),
    Interval(start=datetime(2025, 10, 11, 4, 0), end=datetime(2025, 10, 11, 4, 15)),
    Interval(start=datetime(2025, 10, 11, 8, 0), end=datetime(2025, 10, 11, 8, 15)),
    Interval(start=datetime(2025, 10, 11, 12, 0), end=datetime(2025, 10, 11, 12, 15)),
    Interval(start=datetime(2025, 10, 11, 16, 0), end=datetime(2025, 10, 11, 16, 15)),
    Interval(start=datetime(2025, 10, 11, 20, 0), end=datetime(2025, 10, 11, 20, 15)),
    Interval(start=datetime(2025, 10, 12, 0, 0), end=datetime(2025, 10, 12, 0, 1))
  ]

def test_at_time():
  pass

def test_daily():
  pass

def test_weekly():
  pass

def test_monthly():
  pass

def test_not():
  pass

def test_nth_weekday_set():
  pass

def test_union():
  pass

def test_intersection():
  pass

def test_fromJSON():
  assert fromJSON('2025-11-10') == datetime(2025, 11, 10)
  assert fromJSON('12:00') == time(hour=12)
  assert fromJSON('01:30') == time(hour=1, minute=30)
  assert fromJSON('01:30:59') == time(hour=1, minute=30, second=59)
  assert fromJSON('3d')  == timedelta(days=3)
  assert fromJSON('10m') == timedelta(minutes=10)
  assert fromJSON('10s') == timedelta(seconds=10)
  assert fromJSON('10w') == timedelta(days=70)

  assert fromJSON([
    "explicit",
    '2025-11-10',
    '2025-01-20',
    '2025-02-14'
  ]) == Explicit([
    Interval.fromDate(datetime(2025, 11, 10)),
    Interval.fromDate(datetime(2025,  1, 20)),
    Interval.fromDate(datetime(2025,  2, 14)),
  ])

  assert fromJSON(["weekly", 5, 6]) == Weekly({5, 6})

  assert fromJSON(["monthly", 28, 29, 30]) == Monthly({28, 29, 30})
  assert fromJSON(["nth", 3, 1])           == NthWeekday(3, 1)

  assert fromJSON(
    ["|", ["explicit", '2025-11-10'], ["explicit", '2025-01-20']]
  ) == Union([
    Explicit([Interval.fromDate(datetime(2025, 11, 10))]),
    Explicit([Interval.fromDate(datetime(2025,  1, 20))])
  ])

  assert fromJSON(
    ["&", ["explicit", '2025-11-10'], ["explicit", '2025-01-20']]
  ) == Intersection([
    Explicit([Interval.fromDate(datetime(2025, 11, 10))]),
    Explicit([Interval.fromDate(datetime(2025,  1, 20))])
  ])

  assert fromJSON(["~", ["weekly", 5, 6]]) == Not(Weekly({5, 6}))

  assert fromJSON(["++", "3d"])             == Periodic(3 * day, 1 * day)
  assert fromJSON(["++", "3d", "1h"])       == Periodic(3 * day, 1 * hour)
  assert fromJSON(["++", "3d", "1h", "8h"]) == Periodic(3 * day, 1 * hour, 8 * hour)

  assert fromJSON(["@", "12:00", "15m"]) == AtTime(time(hour=12), 15 * minute)

  assert fromJSON(
    ["@", "20:30", ["+", "3h", "15m"]]
  ) == AtTime(
    time(hour=20, minute=30),
    timedelta(hours=3, minutes=15)
  )

  assert fromJSON(
    ["@", "20:30", ["*", 3, "15m"]]
  ) == AtTime(time(hour=20, minute=30), timedelta(minutes=45))


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
