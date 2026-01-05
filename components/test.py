#! /usr/bin/env python

""" of calendar functions"""

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
        assert startOfWeek(datetime(year, month, day)).weekday() == 0

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

  assert     i1.within(now + 3 * day)
  assert not i1.within(now + 3 * day + 1 * second)
  assert     i1.within(now + 1 * day)
  assert     i1.within(tomorrow)
  assert not i1.within(now - 1 * minute)
  assert not i1.within(now + 3 * day + 1 * minute)

  for i in [i2, i3]:
    assert i1.intersects(i)
  assert not i1.intersects(i4)

  lopen = LeftOpen(today)
  ropen = RightOpen(today)
  fin   = Closed(today - 2 * hour, today - hour)
  fin2  = Closed(today - 1 * hour, today + hour)

  assert lopen.intersects(ropen)
  assert ropen.intersects(lopen)
  assert Open().contains(fin)
  assert Open().contains(lopen)
  assert Open().contains(ropen)
  assert lopen.contains(fin)
  assert not ropen.contains(fin)

  assert Open().intersects(fin)
  assert Open().intersects(fin2)

  assert lopen.intersects(fin2)
  assert ropen.intersects(fin2)

  assert lopen.intersection(fin2) == Closed(fin2.start, today)
  assert ropen.intersection(fin2) == Closed(today, fin2.end)

def test_display_month():
  pass

def test_interval_sequence():
  assert list(
    Interval.fromStartDuration(datetime(2025, 11, 10), 15 * minute)
    .sequence(5 * minute)
  ) == [
    Interval.fromStartDuration(datetime(2025, 11, 10),        5 * minute),
    Interval.fromStartDuration(datetime(2025, 11, 10, 0, 5),  5 * minute),
    Interval.fromStartDuration(datetime(2025, 11, 10, 0, 10), 5 * minute)
  ]

  assert list(
    Interval.fromStartDuration(datetime(2025, 11, 10), 3 * hour)
    .sequence(5 * minute, 1 * hour)
  ) == [
    Interval.fromStartDuration(datetime(2025, 11, 10, 0, 0), 5 * minute),
    Interval.fromStartDuration(datetime(2025, 11, 10, 1, 0), 5 * minute),
    Interval.fromStartDuration(datetime(2025, 11, 10, 2, 0), 5 * minute)
  ]

  assert list(
    Interval.fromStartDuration(datetime(2025, 11, 10, 0, 0), 3 * hour)
    .sequence(5 * minute, 1 * hour, 2 * minute)
  )  == [
    Interval.fromStartDuration(datetime(2025, 11, 10, 0, 2), 5 * minute),
    Interval.fromStartDuration(datetime(2025, 11, 10, 1, 2), 5 * minute),
    Interval.fromStartDuration(datetime(2025, 11, 10, 2, 2), 5 * minute)
  ]

def test_interval_merge_consecutive():
  assert list(Interval.mergeConsecutive([
    Closed(datetime(2025, 11, 10, 14, 30), datetime(2025, 11, 10, 15, 00))
  ])) == [
    Closed(datetime(2025, 11, 10, 14, 30), datetime(2025, 11, 10, 15, 00))
  ]

  assert list(Interval.mergeConsecutive([
    Closed(datetime(2025, 11, 10, 14, 30), datetime(2025, 11, 10, 15)),
    Closed(datetime(2025, 11, 10, 15, 00), datetime(2025, 11, 10, 16)),
    Closed(datetime(2025, 11, 10, 16, 00), datetime(2025, 11, 10, 19, 39))
  ])) == [Closed(datetime(2025, 11, 10, 14, 30), datetime(2025, 11, 10, 19,  39))]

  assert list(Interval.mergeConsecutive([
    Closed(datetime(2025, 11, 10, 14, 30), datetime(2025, 11, 10, 14, 45)),
    Closed(datetime(2025, 11, 10, 15, 00), datetime(2025, 11, 10, 16, 1)),
    Closed(datetime(2025, 11, 10, 16, 00), datetime(2025, 11, 10, 19, 39))
  ])) == [
    Closed(datetime(2025, 11, 10, 14, 30), datetime(2025, 11, 10, 14,  45)),
    Closed(datetime(2025, 11, 10, 15, 00), datetime(2025, 11, 10, 19,  39)),
  ]

def test_interval_within():
  assert Closed(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).within(datetime(2025, 10, 11, 12, 30)) == True

  assert Closed(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).within(datetime(2025, 10, 12, 0, 0)) == True

  assert Closed(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).within(datetime(2025, 10, 12, 23, 59, 59, 999999)) == False

  assert Closed(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).within(datetime(2025, 10, 10, 23, 59, 59, 999999)) == False

  assert Closed(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).within(datetime(2025, 10, 9, 9, 30)) == False


def test_interval_intersects():
  assert Closed(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).intersects(Closed(
    datetime(2025, 10, 11, 12, 30),
    datetime(2025, 10, 11, 13, 00)
  )) == True

  assert Closed(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).intersects(Closed(
    datetime(2025, 10, 10, 23, 30),
    datetime(2025, 10, 10, 23, 59, 59, 999999)
  )) == False

  assert Closed(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).intersects(Closed(
    datetime(2025, 10, 10, 23, 30),
    datetime(2025, 10, 11)
  )) == True

  assert Closed(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ).intersects(Closed(
    datetime(2025, 10, 12),
    datetime(2025, 10, 13)
  )) == True

def test_interval_intersection():
  assert Closed(
    datetime(2025, 10, 11, 16, 00),
    datetime(2025, 10, 11, 16, 45)
  ).intersection(Closed(
    datetime(2025, 10, 11, 16, 30),
    datetime(2025, 10, 11, 17, 20)
  )) == Closed(
    datetime(2025, 10, 11, 16, 30),
    datetime(2025, 10, 11, 16, 45)
  )

def test_interval_ordinals():
  assert list(Closed(
    datetime(2025, 10, 11, 16, 30),
    datetime(2025, 10, 11, 17, 30)
  ).ordinals()) == [739535]

  assert list(Closed(
    datetime(2025, 10, 11, 16, 30),
    datetime(2025, 10, 12, 17, 30)
  ).ordinals()) == [739535, 739536]

def test_explicit():
  # no overlap
  assert list(Explicit([
    Closed(
      datetime(2025, 10, 11, 16, 00),
      datetime(2025, 10, 11, 16, 30)
    ), Closed(
      datetime(2025, 10, 11, 16, 45),
      datetime(2025, 10, 11, 17, 20)
    ), Closed(
      datetime(2025, 10, 11, 17, 35),
      datetime(2025, 10, 11, 17, 47)
    )
  ]).intervals(Closed(
      datetime(2025, 10, 10, 16, 00),
      datetime(2025, 10, 13, 16, 30),
  ))) == [
    Closed(
      datetime(2025, 10, 11, 16, 00),
      datetime(2025, 10, 11, 16, 30)
    ), Closed(
      datetime(2025, 10, 11, 16, 45),
      datetime(2025, 10, 11, 17, 20)
    ), Closed(
      datetime(2025, 10, 11, 17, 35),
      datetime(2025, 10, 11, 17, 47)
    )
  ]

  # no overlap
  assert list(Explicit([
    Closed(
      datetime(2025, 10, 11, 16, 00),
      datetime(2025, 10, 11, 16, 30)
    ), Closed(
      datetime(2025, 10, 11, 16, 45),
      datetime(2025, 10, 11, 17, 20)
    ), Closed(
      datetime(2025, 10, 11, 17, 15),
      datetime(2025, 10, 11, 17, 47)
    )
  ]).intervals(Closed(
      datetime(2025, 10, 10, 16, 00),
      datetime(2025, 10, 13, 16, 30),
  ))) == [
    Closed(
      datetime(2025, 10, 11, 16, 00),
      datetime(2025, 10, 11, 16, 30)
    ), Closed(
      datetime(2025, 10, 11, 16, 45),
      datetime(2025, 10, 11, 17, 47)
    )
  ]

def test_periodic():
  assert list(Periodic(
    4 * hour,
    15 * minute,
  ).intervals(
    Interval.fromDate(datetime(2025, 10, 11))
  )) == [
    Closed(start=datetime(2025, 10, 11, 0, 0), end=datetime(2025, 10, 11, 0, 15)),
    Closed(start=datetime(2025, 10, 11, 4, 0), end=datetime(2025, 10, 11, 4, 15)),
    Closed(start=datetime(2025, 10, 11, 8, 0), end=datetime(2025, 10, 11, 8, 15)),
    Closed(start=datetime(2025, 10, 11, 12, 0), end=datetime(2025, 10, 11, 12, 15)),
    Closed(start=datetime(2025, 10, 11, 16, 0), end=datetime(2025, 10, 11, 16, 15)),
    Closed(start=datetime(2025, 10, 11, 20, 0), end=datetime(2025, 10, 11, 20, 15))
  ]

  assert list(Periodic(
    4 * hour,
    20 * minute,
    -10 * minute
  ).intervals(
    Interval.fromDate(datetime(2025, 10, 11))
  )) == [
    Closed(start=datetime(2025, 10, 11, 0, 0), end=datetime(2025, 10, 11, 0, 10)),
    Closed(start=datetime(2025, 10, 11, 3, 50), end=datetime(2025, 10, 11, 4, 10)),
    Closed(start=datetime(2025, 10, 11, 7, 50), end=datetime(2025, 10, 11, 8, 10)),
    Closed(start=datetime(2025, 10, 11, 11, 50), end=datetime(2025, 10, 11, 12, 10)),
    Closed(start=datetime(2025, 10, 11, 15, 50), end=datetime(2025, 10, 11, 16, 10)),
    Closed(start=datetime(2025, 10, 11, 19, 50), end=datetime(2025, 10, 11, 20, 10)),
    Closed(start=datetime(2025, 10, 11, 23, 50), end=datetime(2025, 10, 12, 0, 0))
  ]

def test_at_time():
  assert list(AtTime(
    time(8, 0, 0),
    2 * hour + 30 * minute
  ).intervals(Interval.fromDate(
    datetime(2025, 10, 11)
  ))) == [
    Closed(
      datetime(2025, 10, 11, 8),
      datetime(2025, 10, 11, 10, 30)
    )
  ]

  assert list(AtTime(
    time(8, 0, 0),
    2 * hour + 30 * minute
  ).intervals(Interval.fromDate(
    datetime(2025, 10, 11),
    datetime(2025, 10, 12)
  ))) == [
    Closed(
      datetime(2025, 10, 11, 8),
      datetime(2025, 10, 11, 10, 30)
    ),
    Closed(
      datetime(2025, 10, 12, 8),
      datetime(2025, 10, 12, 10, 30)
    )
  ]

def test_weekly():
  assert list(
    Weekly({0, 2, 4}).intervals(
      Interval.fromDate(
        datetime(2025, 12, 7),
        datetime(2025, 12, 14)
      )
    )
  ) == [
    # It's expected that the event will end one minute early.
    Interval.fromStartDuration(
      datetime(2025, 12, 8),
      1 * day
    ),
    Interval.fromStartDuration(
      datetime(2025, 12, 10),
      1 * day
    ),
    Interval.fromStartDuration(
      datetime(2025, 12, 12),
      1 * day
    )
  ]

  # check whether adjacent day are merged
  assert list(
    Weekly({0, 2, 3}).intervals(
      Interval.fromDate(
        datetime(2025, 12, 7),
        datetime(2025, 12, 14)
      )
    )
  ) == [
    Interval.fromStartDuration(
      datetime(2025, 12, 8),
      1 * day
    ),
    # It's expected that the event will end one minute early.
    Interval.fromStartDuration(
      datetime(2025, 12, 10),
      2 * day
    )
  ]

def test_monthly():
  assert list(
    Monthly({14, 30, 10}).intervals(
      Interval.fromDate(
        datetime(2025, 12, 1),
        datetime(2025, 12, 31)
      )
    )
  ) == [
    # It's expected that the event will end one minute early.
    Interval.fromStartDuration(
      datetime(2025, 12, 10),
      1 * day
    ),
    Interval.fromStartDuration(
      datetime(2025, 12, 14),
      1 * day
    ),
    Interval.fromStartDuration(
      datetime(2025, 12, 30),
      1 * day
    )
  ]

  # check that adjacent days are merged
  assert list(
    Monthly({10, 11, 15}).intervals(
      Interval.fromDate(
        datetime(2025, 12, 1),
        datetime(2025, 12, 31)
      )
    )
  ) == [
    Interval.fromStartDuration(
      datetime(2025, 12, 10),
      2 * day
    ),
    Interval.fromStartDuration(
      datetime(2025, 12, 15),
      1 * day
    )
  ]

  # check that giving a month works as expected
  assert list(
    Monthly({10, 11, 15}, 11).intervals(
      Interval.fromDate(
        datetime(2025, 10, 1),
        datetime(2025, 12, 31)
      )
    )
  ) == [
    Interval.fromStartDuration(
      datetime(2025, 11, 10),
      2 * day
    ),
    Interval.fromStartDuration(
      datetime(2025, 11, 15),
      1 * day
    )
  ]

  # check that monthy repetition works
  assert list(
    Monthly({10}).intervals(
      Interval.fromDate(
        datetime(2025, 10, 1),
        datetime(2025, 12, 31)
      )
    )
  ) == [
    Interval.fromStartDuration(
      datetime(2025, 10, 10),
      1 * day
    ),
    Interval.fromStartDuration(
      datetime(2025, 11, 10),
      1 * day
    ),
    Interval.fromStartDuration(
      datetime(2025, 12, 10),
      1 * day
    )
  ]

def test_nth_weekday_set():
  # every third wednesday
  assert list(
    NthWeekday(3, 2).intervals(
      Interval.fromDate(
        datetime(2025, 10, 1),
        datetime(2025, 12, 31)
      )
    )
  ) == [
    Interval.fromStartDuration(
      datetime(2025, 10, 15),
      1 * day
    ),
    Interval.fromStartDuration(
      datetime(2025, 11, 19),
      1 * day
    ),
    Interval.fromStartDuration(
      datetime(2025, 12, 17),
      1 * day
    )
  ]

  # every third wednesday of november
  assert list(
    NthWeekday(3, 2, 11).intervals(
      Interval.fromDate(
        datetime(2025, 10, 1),
        datetime(2025, 12, 31)
      )
    )
  ) == [
    Interval.fromStartDuration(
      datetime(2025, 11, 19),
      1 * day
    )
  ]

def test_shift():
  assert list(Shift(2 * hour, AtTime(
    time(8, 0, 0),
    2 * hour + 30 * minute
  )).intervals(Interval.fromDate(
    datetime(2025, 10, 11)
  ))) == [
    Closed(
      datetime(2025, 10, 11, 10,  0),
      datetime(2025, 10, 11, 12, 30)
    )
  ]

  assert list(Shift(-2 * hour, AtTime(
    time(8, 0, 0),
    2 * hour + 30 * minute
  )).intervals(Interval.fromDate(
    datetime(2025, 10, 11)
  ))) == [
    Closed(
      datetime(2025, 10, 11, 6,  0),
      datetime(2025, 10, 11, 8, 30)
    )
  ]

def test_not():
  assert list(Not(AtTime(
    time(8, 0, 0),
    2 * hour + 30 * minute
  )).intervals(Interval.fromDate(
    datetime(2025, 10, 11)
  ))) == [
    Closed(
      datetime(2025, 10, 11, 0 , 0),
      datetime(2025, 10, 11, 8,  0)
    ),
    Closed(
      datetime(2025, 10, 11, 10 , 30),
      datetime(2025, 10, 12, 0, 0)
    )
  ]

  assert list(
    Not(Weekly({2})
  ).intervals(Interval.fromDate(
    datetime(2025, 10, 5),
    datetime(2025, 10, 12)
  ))) == [
    Closed(
      datetime(2025, 10,  5,  0, 0),
      datetime(2025, 10,  8,  0, 0)
    ),
    Closed(
      datetime(2025, 10,  8, 23, 59),
      datetime(2025, 10, 13,  0, 0)
    )
  ]

def test_union():
  assert list(
    Union([
      Periodic(2 * hour, 30 * minute),
      Periodic(3 * hour, 15 * minute)
    ]).intervals(
      Interval.fromDate(datetime(2025, 11, 10))
    )
  ) == [
    Closed(datetime(2025, 11, 10, 0,  0), datetime(2025, 11, 10, 0,  30)),
    Closed(datetime(2025, 11, 10, 2,  0), datetime(2025, 11, 10, 2,  30)),
    Closed(datetime(2025, 11, 10, 3,  0), datetime(2025, 11, 10, 3,  15)),
    Closed(datetime(2025, 11, 10, 4,  0), datetime(2025, 11, 10, 4,  30)),
    Closed(datetime(2025, 11, 10, 6,  0), datetime(2025, 11, 10, 6,  30)),
    Closed(datetime(2025, 11, 10, 8,  0), datetime(2025, 11, 10, 8,  30)),
    Closed(datetime(2025, 11, 10, 9,  0), datetime(2025, 11, 10, 9,  15)),
    Closed(datetime(2025, 11, 10, 10, 0), datetime(2025, 11, 10, 10, 30)),
    Closed(datetime(2025, 11, 10, 12, 0), datetime(2025, 11, 10, 12, 30)),
    Closed(datetime(2025, 11, 10, 14, 0), datetime(2025, 11, 10, 14, 30)),
    Closed(datetime(2025, 11, 10, 15, 0), datetime(2025, 11, 10, 15, 15)),
    Closed(datetime(2025, 11, 10, 16, 0), datetime(2025, 11, 10, 16, 30)),
    Closed(datetime(2025, 11, 10, 18, 0), datetime(2025, 11, 10, 18, 30)),
    Closed(datetime(2025, 11, 10, 20, 0), datetime(2025, 11, 10, 20, 30)),
    Closed(datetime(2025, 11, 10, 21, 0), datetime(2025, 11, 10, 21, 15)),
    Closed(datetime(2025, 11, 10, 22, 0), datetime(2025, 11, 10, 22, 30)),
  ]

def test_intersection():
  assert list(
    Intersection([
      Weekly({1, 3, 5}),
      AtTime(time(8, 0, 0), 1 * hour)
    ]).intervals(
      Interval.fromDate(
        datetime(2025, 10, 5),
        datetime(2025, 10, 12)
      )
    )
  ) == [
    Closed(datetime(2025, 10, 7,  8, 0), datetime(2025, 10, 7,  9, 0)),
    Closed(datetime(2025, 10, 9,  8, 0), datetime(2025, 10, 9,  9, 0)),
    Closed(datetime(2025, 10, 11, 8, 0), datetime(2025, 10, 11, 9, 0))
  ]

  assert list(
    Intersection([
      Periodic(8 * hour, 15 * minute),
      Explicit([Interval.fromDate(datetime(2025, 10, 11))])
    ]).intervals()
  ) == [
    Closed(datetime(2025, 10, 11,  0, 0), datetime(2025, 10, 11,  0, 15)),
    Closed(datetime(2025, 10, 11,  8, 0), datetime(2025, 10, 11,  8, 15)),
    Closed(datetime(2025, 10, 11,  16, 0), datetime(2025, 10, 11, 16, 15)),
  ]

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
    "dates",
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
    ["|", ["dates", '2025-11-10'], ["dates", '2025-01-20']]
  ) == Union([
    Explicit([Interval.fromDate(datetime(2025, 11, 10))]),
    Explicit([Interval.fromDate(datetime(2025,  1, 20))])
  ])

  assert fromJSON(
    ["&", ["dates", '2025-11-10'], ["dates", '2025-01-20']]
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

  assert fromJSON(
    ["range", "2025-10-01", "2025-10-31"]
  ) == Explicit(
    [Closed(datetime(2025, 10, 1), datetime(2025, 10, 31))]
  )

def test_interval_span():
  dt = datetime(2025, 10, 11)
  assert Explicit([Interval.fromDate(dt)]).span() == Closed(dt, dt + day)
  assert Periodic(4 * hour, 15 * minute).span() == Open()
  assert Monthly({23, 24, 25}).span() == Open()
  assert Weekly({2, 3}).span() == Open()
  assert NthWeekday(2, 3).span() == Open()

  assert Union([
    Periodic(4 * hour, 15 * minute),
    Monthly({23, 24, 25}),
  ]).span() == Open()

  assert Intersection([
    Periodic(4 * hour, 15 * minute),
    Monthly({23, 24, 25}),
  ]).span() == Open()

  assert Intersection([
    Periodic(4 * hour, 15 * minute),
    Monthly({23, 24, 25}),
    Explicit([
      Interval.fromDate(datetime(2025, 10, 1), datetime(2025, 10, 31))
    ])
  ]).span() == Interval.fromDate(datetime(2025, 10, 1), datetime(2025, 10, 31))

  Closed(
    datetime(2025, 10, 11, 16, 00),
    datetime(2025, 10, 11, 16, 30)
  ).span(Closed(
    datetime(2025, 10, 11, 16, 45),
    datetime(2025, 10, 11, 17, 20)
  )) == Closed(
    datetime(2025, 10, 11, 16, 00),
    datetime(2025, 10, 11, 17, 20)
  )

def test_completions():
  assert not any(
    completed for (_, completed)
    in Periodic(2 * hour, 15 * minute).completions(
      window = Interval.fromDate(datetime(2025, 10, 11)),
      history = {}
    )
  )

  assert {
    interval: completed
    for (interval, completed)
    in Periodic(8 * hour, 15 * minute).completions(
      window = Interval.fromDate(datetime(2025, 10, 11)), history = {
        datetime(2025, 10, 11, 0, 10),
      }
    )
  } == {
    Closed(start=datetime(2025, 10, 11, 0, 0), end=datetime(2025, 10, 11, 0, 15)): True,
    Closed(start=datetime(2025, 10, 11, 8, 0), end=datetime(2025, 10, 11, 8, 15)): False,
    Closed(start=datetime(2025, 10, 11, 16, 0), end=datetime(2025, 10, 11, 16, 15)): False
  }

  assert {
    interval: completed
    for (interval, completed)
    in Periodic(8 * hour, 15 * minute).completions(
      window = Interval.fromDate(datetime(2025, 10, 11)), history = {
        datetime(2025, 10, 11, 8, 10),
      }
    )
  } == {
    Closed(start=datetime(2025, 10, 11, 0, 0), end=datetime(2025, 10, 11, 0, 15)): False,
    Closed(start=datetime(2025, 10, 11, 8, 0), end=datetime(2025, 10, 11, 8, 15)): True,
    Closed(start=datetime(2025, 10, 11, 16, 0), end=datetime(2025, 10, 11, 16, 15)): False
  }

  assert {
    interval: completed
    for (interval, completed)
    in Periodic(8 * hour, 15 * minute).completions(
      window = Interval.fromDate(datetime(2025, 10, 11)), history = {
        datetime(2025, 10, 11, 16, 10),
      }
    )
  } == {
    Closed(start=datetime(2025, 10, 11, 0, 0), end=datetime(2025, 10, 11, 0, 15)): False,
    Closed(start=datetime(2025, 10, 11, 8, 0), end=datetime(2025, 10, 11, 8, 15)): False,
    Closed(start=datetime(2025, 10, 11, 16, 0), end=datetime(2025, 10, 11, 16, 15)): True
  }

  assert {
    interval: completed
    for (interval, completed)
    in Periodic(8 * hour, 15 * minute).completions(
      window = Interval.fromDate(datetime(2025, 10, 11)), history = {
        datetime(2025, 10, 11, 0, 10),
        datetime(2025, 10, 11, 16, 10),
      }
    )
  } == {
    Closed(start=datetime(2025, 10, 11, 0, 0), end=datetime(2025, 10, 11, 0, 15)): True,
    Closed(start=datetime(2025, 10, 11, 8, 0), end=datetime(2025, 10, 11, 8, 15)): False,
    Closed(start=datetime(2025, 10, 11, 16, 0), end=datetime(2025, 10, 11, 16, 15)): True
  }

  assert {
    interval: completed
    for (interval, completed)
    in Intersection([
      Periodic(8 * hour, 15 * minute),
      Explicit([Interval.fromDate(datetime(2025, 10, 11))])
    ]).completions({
      datetime(2025, 10, 11,  0, 15),
      datetime(2025, 10, 11, 16, 15)
    })
  } == {
    Closed(start=datetime(2025, 10, 11, 0, 0), end=datetime(2025, 10, 11, 0, 15)): True,
    Closed(start=datetime(2025, 10, 11, 8, 0), end=datetime(2025, 10, 11, 8, 15)): False,
    Closed(start=datetime(2025, 10, 11, 16, 0), end=datetime(2025, 10, 11, 16, 15)): True
  }


def main(*args):
  import traceback
  self = __import__(__name__)
  match args:
    case []|["all"]:
      for test in sorted(dir(self)):
        if test.startswith('test_'):
          print(f"{test}...", end ='')
          try:
            getattr(self, test)()
            print("ok")
          except BaseException as e:
            print("err")
            traceback.print_exception(e)
    case [test]:
      getattr(self, test)()
    case invalid: raise ValueError(f"Invalid Command: {" ".join(invalid)}")

if __name__ == "__main__":
  main(*sys.argv[1:])
