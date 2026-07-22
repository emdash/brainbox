#! /usr/bin/env python

"""Implements calendar logic for scheduled and repeating tasks, and habits.

The goal is to support arbitrary patterns of repetition, and a variety
of different types of report. Eventually, to support syncing with ical
google calendar, and other formats.

For the timing requirements of this application, second-precision is
overkill. We assume that there are exactly 24 hours in a day, 60
minutes in an hour, 60 seconds in a minute, and so on. Technically,
this is wrong because of leap seconds and god knows what else. For the
sake of simplicity, we do a number of calculations as if a second is
always exactly 1/86,400 of a solar day.
"""

from datetime import date, datetime, time, timedelta
from dataclasses import dataclass, replace, InitVar, field
from functools import reduce

import graph
import itertools
import json
import os
import sys
import traceback

import tabulate

# convenient constants for working with time deltas.
second   = timedelta(seconds = 1)
minute   = timedelta(minutes = 1)
hour     = timedelta(hours = 1)
day      = timedelta(days = 1)
week     = timedelta(weeks = 1)

# define these relative to the start time of the script.
now       = datetime.now()
today     = datetime(now.year, now.month, now.day)
yesterday = today - 1 * day
tomorrow  = today + day
origin    = datetime(1, 1, 1)

def debug(*args):
  print(*args, file=sys.stderr)
  return args[-1]

def debug_iter(prefix, it):
  for x in it:
    yield debug(prefix, x)

def count(dt, td):
  i = dt
  while True:
    yield i
    i += td

def firstOfMonth(month=today.month, year=today.year):
  """Return the date on which the given month begins."""
  return datetime(year, month, 1)

def startOfWeek(dt):
  """Return the monday which begins the week containing the given day."""
  return dt - timedelta(days=dt.weekday())

def daysOfMonth(month=today.month, year=today.year):
  """Yields all the days of the given month, in order."""
  dt = firstOfMonth(year, month)
  if dt.month == 12:
    end = datetime(dt.year + 1, 1, 1)
  else:
    end = datetime(dt.year, dt.month + 1, 1)

  return itertools.takewhile(lambda dt: dt < end, count(dt, day))

def startOfDay(dt):
  """Return the start of the day referred to by the given timestamp."""
  return datetime(dt.year, dt.month, dt.day)

def endOfDay(dt):
  """Return the time just before the start of the next day of the given timestamp."""
  return dt + day - timedelta.resolution

def nextMonth(month, year=today.year):
  """Return the first day of the month after this one."""
  match month + 1:
    case 13: return datetime(year = year + 1, month = 1, day=1)
    case m:  return datetime(year = year, month = m, day = 1)

def prevMonth(month, year=today.year):
  """Return the first day of the month after this one."""
  match month - 1:
    case 0: return datetime(year = year - 1, month = 12, day=1)
    case m: return datetime(year = year, month = m - 1, day=1)

def lastOfMonth(month, year=today.year):
  """Return the last day of the given month."""
  return nextMonth(month, year) - 1 * day

def firstWeekday(weekday, month=today.month, year=today.year):
  """Return the first instance of the given weekday of the given month."""
  dt = firstOfMonth(month, year)
  while dt.weekday() != weekday:
    dt += 1 * day
  return dt

def lastWeekday(weekday, month=today.month, year=today.year):
  """Return the last instance of the given weekday of the given month."""
  dt = lastOfMonth(month, year)
  while dt.weekday() != weekday:
    dt -= 1 * day
  return dt

def nthWeekday(n, weekday, month=today.month, year=today.year):
  """Return the date of the nth instance of weekday in the given month.

  Negative values of n are relative to the last weekday.
  """
  if n > 0:
    return firstWeekday(weekday, month, year) + (n - 1) * 7 * day
  elif n < 0:
    return lastWeekday(weekday, month, year) - (abs(n) - 1) * 7  * day
  else:
    raise ValueError("`n` cannot be 0")

@dataclass(order=True, frozen=True)
class Interval:
  """The time between two timestamps, or a start timestamp and duration.

  We can do various operations on intervals, including tests for
  containment and intersection, and subdividing in various ways.
  """

  def within(self, dt: datetime):
    """True if the given timestamp falls within self."""
    raise NotImplemented

  def contains(self, i: Interval):
    """True if the given interval is completely contained within self."""
    raise NotImplemented

  def intersects(self, i: Interval):
    """True if the given interval touches or is partially contained within self."""
    match self.intersection(i):
      case Empty(): return False
      case _:       return True

  def span(self, i: Interval):
    """The smallest interval containing both self and i."""
    raise NotImplemented

  @classmethod
  def fromStartDuration(self, start, duration):
    "Create an interval from a timestamp and duration."
    return Closed(start, start + duration)

  @classmethod
  def fromDate(self, dt, end=None):
    """Construct an interval that spans a date or date range."""
    match end:
      case None: return Closed(startOfDay(dt), startOfDay(dt  + 1 * day))
      case end:  return Closed(startOfDay(dt), startOfDay(end + 1 * day))

  @classmethod
  def mergeConsecutive(self, intervals):
    """Yields intervals, merging runs of intersecting intervals."""

    def yne():
      match next:
        case Empty():  pass
        case nonempty: yield next

    its = iter(intervals)
    try:
      next = its.__next__()
    except StopIteration:
      return ()

    for i in its:
      if next.intersects(i):
        next = next.span(i)
      else:
        yield from yne()
        next = i
    yield from yne()

  def sequence(self, duration, period=None, phase=None):
    """Yield evenly-spaced intervals intersecting the window."""
    if period is None:
      period = duration

    if phase is None:
      phase = timedelta()

    assert isinstance(duration, timedelta)
    assert isinstance(period, timedelta)
    assert period > timedelta()
    assert duration > timedelta()
    assert phase >= timedelta()
    assert phase < period

    i = self.start + phase
    end = self.end
    while i < end:
      yield Interval.fromStartDuration(i, duration)
      i += period

  def sequenceMonths(self):
    i = self.start
    while i <= self.end:
      yield firstOfMonth(self.year, self.month)
      i = nextMonth(i.year, i.month)

  def ordinals(self, start=None):
    """An iterator over the julian ordinals which this interval intersects.

    For any closed interval, this will always yield at least one
    value. For right-open intervals, counts forward from start
    timestamp. For left-open intervals, counts backward. For open
    intervals, raises an error.
    """
    raise NotImplemented

@dataclass(order=True, frozen=True)
class Empty(Interval):
  @property
  def duration(self):        return timedelta()
  def within(self, _):       return False
  def contains(self, _):     return False
  def span(self, i):         return i
  def intersection(self, _): return self
  def ordinals(self, _):     return ()
  def __add__(self, _):      return self
  def __radd__(self, _):     return self
  def sequence(self, _):     return ()
  def sequenceMonths(self):  return ()
  def invert(self):          yield Open()

@dataclass(order=True, frozen=True)
class Open(Interval):
  @property
  def within(self, _):       return True
  def contains(self, _):     return True
  def span(self, _):         return self
  def intersection(self, i): return i
  def ordinals(self, _):     raise ValueError("Infinite interval")
  def is_finite(self):       return False
  def __add__(self, _):      return self
  def __radd__(self, _):     return self
  def sequence(self, _):     raise ValueError("infinite interval")
  def sequenceMonths(self, _): raise ValueError("infinite interval")
  def invert(self):          yield Empty()

@dataclass(order=True, frozen=True)
class LeftOpen(Interval):
  end: datetime

  def __add__(self, td): return LeftOpen(self.end + td)
  def __radd__(self, td): return LeftOpen(self.end + td)

  def within(self, dt):
    return dt <= self.end

  def contains(self, i):
    match i:
      case Empty():     return False
      case Open():      return True
      case LeftOpen():  return self.end >= i.end
      case RightOpen(): return False
      case Closed():    return i.end <= self.end

  def intersection(self, i):
    match i:
      case Empty():     return i
      case Open():      return self
      case LeftOpen():  return LeftOpen(min(i.end, self.end))
      case RightOpen():
        if i.start <= self.end:
          return Closed(i.start, self.end)
        else:
          return Empty()
      case Closed():
        if i.within(self.end) or self.within(i.start):
          return Closed(i.start, min(i.end, self.end))
        else:
          return Empty()

  def span(self, i):
    match i:
      case Empty(): return self
      case Open():  return i
      case LeftOpen() | Closed(): return LeftOpen(max(i.end, self.end))
      case RightOpen(): return Open()

  def ordinals(self, i):
    i = end.toordinal()
    while True:
      yield i
      i -= 1

  def invert(self):
    yield RightOpen(self.end)

@dataclass(order=True, frozen=True)
class RightOpen(Interval):
  start: datetime

  def __add__(self, td): return RightOpen(self.start + td)
  def __radd__(self, td): return RightOpen(self.start + td)

  def within(self, dt):
    return self.start <= dt

  def contains(self, i):
    match i:
      case Empty():     return False
      case Open():      return True
      case LeftOpen():  return False
      case RightOpen(): return self.start <= i.start
      case Closed():    return i.start >= self.start
    raise ValueError("wtf", i)

  def intersection(self, i):
    match i:
      case Empty():     return i
      case Open():      return self
      case RightOpen(): return RightOpen(max(i.end, self.end))
      case LeftOpen():
        if self.start <= i.end:
          return Closed(self.start, i.end)
        else:
          return Empty()
      case Closed():
        if i.within(self.start) or self.within(i.end):
          return Closed(max(i.start, self.start), i.end)
        else:
          return Empty()
    raise ValueError("wtf", i)

  def span(self, i):
    match i:
      case Empty(): return self
      case Open():  return i
      case RightOpen() | Closed(): return RightOpen(min(i.end, self.end))
      case LeftOpen(): return Open()
    raise ValueError("wtf", i)

  def ordinals(self, i):
    i = start.toordinal()
    while True:
      yield i
      i += 1

  def invert(self):
    yield LeftOpen(self.start)

@dataclass(order=True, frozen=True)
class Closed(Interval):
  start : datetime
  end : datetime

  def __add__(self, td): return Closed(self.start + td, self.end + td)
  def __radd__(self, td): return Closed(self.start + td, self.end + td)

  def __post_init__(self):
    assert isinstance(self.start, datetime)
    assert isinstance(self.end, datetime)

  @property
  def duration(self):
    """A time delta from the start of the interval.

    This is assumed to be positive.
    """
    return self.end - self.start

  def within(self, timestamp):
    """True if timestamp occurs on or before start, and strictly before end.

    This is so that back-to-events will not supriously register as
    overlapping.
    """
    # XXX: we're clobbering the timezone here, because datetime
    # complains about naive vs tz-aware dates. It's a rabbit hole I
    # don't want to go down just yet.
    if timestamp is not None:
      return self.start <= timestamp.replace(tzinfo=None) <= self.end

  def contains(self, i):
    match i:
      case Empty(): return False
      case Open(): return False
      case LeftOpen(): return False
      case RightOpen(): return False
      case Closed(): return self.within(i.start) and self.within(i.end)
    raise ValueError("wtf", i)

  def span(self, i):
    """Return the smallest interval containg self and interval."""
    match i:
      case Empty():     return self
      case Open():      return i
      case LeftOpen():  return LeftOpen(max(self.end, i.end))
      case RightOpen(): return RightOpen(min(self.start, i.start))
      case Closed():    return Closed(min(self.start, i.start), max(self.end, i.end))
    raise ValueError("wtf", i)

  def intersection(self, i):
    """Return the portion of two overlapping intervals which intersects.

    This will throw `ValueError` if the two intervals are not overlapping.
    """
    match i:
      case Empty():     return i
      case Open():      return self
      case LeftOpen():
        if self.within(i.end) or i.within(self.start):
          return Closed(self.start, min(self.end, i.end))
        else:
          return Empty()
      case RightOpen():
        if self.within(i.start) or i.within(self.end):
          return Closed(max(self.start, i.start), self.end)
        else:
          return Empty()
      case Closed():
        if self.within(i.start) \
          or self.within(i.end)   \
          or i.within(self.start) \
          or i.within(self.end):
          return Closed(max(self.start, i.start), min(self.end, i.end))
        else:
          return Empty()
    raise ValueError("wtf", self, i)

  def ordinals(self):
    return range(self.start.toordinal(), self.end.toordinal() + 1)

  def invert(self):
    yield LeftOpen(self.start)
    yield RightOpen(self.end)

@dataclass
class DateSet:
  """Represents when an event can happen.

  We can ask a date set whether or not an arbitrary interval
  intersects it, and we can ask for the set for all the intervals it
  contains which intersect the window.

  A DateSet can be finite or infinite. For finite sets, we can find
  the span (i.e. bounding interval, or the smallest interval that
  contains every interval in the set).
  """

  def intersects(self, window):
    """True if window interesects any interval within the dateset."""
    raise NotImplemented

  def span(self):
    """Returns the smallest interval which contains the entire set."""
    raise NotImplemented

  def resolution(self):
    """A hint to the scheduler about the smallest time scales within the set."""
    raise NotImplemented

  def within(self, dt):
    """True if the given dt is part of this set."""
    return self.largestIntervalContaining(dt).within(dt)

  def contains(self, window):
    """True if the given window is completely contained by this set."""
    raise NotImplemented

  def intervals(self, window=None):
    """Return an ordered sequence of intervals which intersect `window`.

    If window is not given, and dateset is finite, then yields every
    interval in the date set.

    If this window is not given, and the dateset is not finite, this
    will raise `ValueError'.
    """
    raise NotImplemented

  def completions(self, history, window=None):
    """Yield tuples of `(intervals, completed)`.

    A single timestamp within an interval is considered a "completion
    event", which discharges the obligation implied by the interval.

    Multiple timestamps within an interval are ignored, as are
    timestamps outside of a completion window.

    `window` is treated the same as in `intervals`.
    """

    for i in self.intervals(window):
      yield (i, any(map(i.within, history)))

  def is_complete(self, history, window=None):
    """True if all intervals within the window have a completion event.

    If window is not given:
      - self is finite     -- uses the entire span.
      - self is not finite -- always returns False
    """
    if window is None and not self.span().is_finite():
      return False
    else:
      return all(completed for (_, completed) in self.completions(history, window))

  def largestIntervalContaining(self, dt=None):
    """Find the largest interval that contains `dt`."""
    raise NotImplemented

@dataclass
class Explicit(DateSet):
  """An explicit list of intervals.

  Intersection and containment is defined in terms of `intervals`, returning true if any
  of the subintervals intersects.
  """

  given : List[Interval]

  def __post_init__(self):
    self.given = list(self.given)

  def is_finite(self):
    return all(i.is_finite() for i in self.given)

  def span(self):
    return reduce(lambda i, j: i.span(j), self.given, Empty())

  def intersects(self, window):
    return any(i.intersects(window) for i in self.intervals(window))

  def contains(self, window):
    return any(i.contains(window) for i in self.given)

  def largestIntervalContaining(self, dt):
    for i in self.given:
      if i.within(dt):
        return i
    return Empty()

  def intervals(self, window=None):
    it = Interval.mergeConsecutive(self.given)
    if window is None:
      return it
    else:
      return filter(window.intersects, it)

  def __inv_merge(self, intervals):
    """Yields intervals, merging runs of intersecting intervals."""

    its = iter(intervals)
    next = its.__next__()

    for i in its:
      match next.intersection(i):
        case Empty():
          yield next
          next = i
        case nonempty:
          next = nonempty
    yield next

  def invert(self):
    return Explicit(
      self.__inv_merge(itertools.chain(*(i.invert() for i in self.given)))
    )

@dataclass
class Implicit(DateSet):
  """Base class for types defining intervals via an implicit function
  `within`, which subclasses must implement.

  Certain patterns of repetition are simpler to define implicitly
  rather than explicitly, particularly when used with logical
  operations.

  An implicit function is a predicate that defines a set, where True
  indicates that its argument is within the boundary of the set.

  We can't know exactly which intervals such a set contains, but we
  can sample it down to some arbitrary resolution and then look for
  runs of contigous sub-intervals. As long as the sample points align
  with the actual subintervals, there won't be any artifacts or gaps.

  Given that most real-world institutions divide the day into
  15-minute intervals, this doesn't seem like a huge problem;
  therefore, a 1-minute resolution is the default, as a compromise
  between precision and performance.

  If you needed more precision, you could decrease the resolution, at
  the expense of performance. Conversely, if you need things to run
  faster, and you don't mind losing some precision, increase the
  resolution to 5-, 10-, or 15- minutes.
  """

  def span(self):
    return Open()

  def contains(self, interval):
    """True if the window is completely contained within this set."""
    # XXX: dubious.
    return self.within(interval.start) and self.within(interval.end)

  def intervals(self, window=None, resolution=minute):
    # sample the set at regular intervals which intersect the current window,
    # merging consecutive subintervals in the final result.
    if window is None:
      window = self.span()
    return Interval.mergeConsecutive(
      filter(self.contains, window.sequence(resolution))
    )

@dataclass
class Union(Implicit):
  """Take the union of arbitrary subsets.

  If all the subsets are finite, then the union over them is finite.
  """

  subsets: set[DateSet]

  def within(self, dt):
    return any(s.within(dt) for s in self.subsets)

  def span(self):
    return reduce(lambda acc, t: acc.span(t.span()), self.subsets, Empty())

  def contains(self, interval):
    return any(s.contains(interval) for s in self.subsets)

  def intersects(self, interval):
    return any(s.intersects(interval) for s in self.subsets)

  # XXX: probably wrong
  def largestIntervalContaining(self, dt):
    return reduce(
      lambda acc, i: acc.span(i.largestIntervalContaining(dt)),
      filter(lambda s: s.within(i), self.subsets)
    )

  # XXX: probably wrong
  def invert(self):
    return Intersection(i.invert() for i in self.subsets)


@dataclass
class Intersection(Implicit):
  """Take the intersection of arbitrary subsets.

  If any of the subsets is finite, then the intersection is finite.
  """

  subsets: set[DateSet]

  def within(self, dt):
    return all(s.within(dt) for s in self.subsets)

  def span(self):
    ret = Open()
    for s in self.subsets:
      match s.span():
        case Empty() as i:
          return i
        case Open():
          pass
        case i:
          ret = ret.intersection(i)
    return ret

  def contains(self, interval):
    return all(s.contains(interval) for s in self.subsets)

  def intersects(self, interval):
    return all(s.intersects(interval) for s in self.subsets)

  # XXX: probably wrong
  def largestIntervalContaining(self, dt):
    return reduce(
      lambda acc, i: acc.intersection(i.largestIntervalContaining(dt)),
      filter(
        lambda s: s.within(i),
        self.subsets)
    )

  # XXX: probably wrong
  def invert(self):
    return Union(i.invert() for i in self.subsets)


@dataclass
class Periodic(Implicit):
  """Repeats evenly at arbitrary time periods."""

  period   : timedelta               # time between intervals
  duration : timedelta = 1 * day     # length of the interval.
  phase    : timedelta = timedelta() # shift start time by up to one period

  def __post_init__(self):
    assert self.duration <= self.period
    assert abs(self.phase) < self.period

  def intersects(self, window):
    return (window.duration >= self.period) \
      or self.largestIntervalContaining(window.start) != Empty() \
      or self.largestIntervalContaining(window.end)   != Empty()

  def largestIntervalContaining(self, dt):
    as_delta = dt - origin
    start = origin + as_delta - ((as_delta - self.phase) % self.period)
    end = start + self.duration
    if start <= dt <= end:
      return Closed(start, end)
    else:
      return Empty()

  # XXX: probably wrong
  def invert(self):
    return Periodic(
      self.period,
      self.phase,
      self.period - self.duration
    )

@dataclass
class AtTime(Implicit):
  """A special-case of Periodic where the period is always exactly one day.

  We don't really need this, but it's more efficient than Periodic,
  and is by far the more common case.

  To schedule an event at multiple times, union multiple AtTime
  instances.
  """
  start    : time
  duration : timedelta
  inverted : bool = False

  def __post_init__(self):
    assert self.duration > timedelta()
    assert self.duration <= day
    # assert (self.start + self.duration) < (1 * day)

  def intersects(self, window):
    return window.duration >= day \
      or window.intersects(self.largestIntervalContaining(window.start))

  def largestIntervalContaining(self, dt):
    start = dt.replace(
      hour = self.start.hour,
      minute = self.start.minute,
      second = self.start.second,
      microsecond = self.start.microsecond
    )
    end = start + self.duration
    if self.inverted:
      if startOfDay(dt) <= dt <= start:
        return Closed(startOfDay(dt), start)
      elif end <= dt <= endOfDay(dt):
        return Closed(end, endOfDay(dt))
      else:
        return Empty()
    else:
      if start <= dt <= end:
        return Closed(start, end)
      else:
        return Empty()

  def invert(self):
    return replace(self, inverted=True)


@dataclass
class Weekly(Implicit):
  """An arbitrary pattern that repeats every week on particular days.

  Multiple days on a given week can be specified.
  """

  which : set[int]
  multi_day = False

  def __post_init__(self):
    assert all(0 <= day < 7 for day in self.which)

  def intersects(self, window):
    return window.duration >= week \
      or window.intersects(self.largestIntervalContaining(window.start)) \
      or window.intersects(self.largestIntervalContaining(window.end))

  # override here to prevent 1-sample gap at end of day, where the
  # ordinal advances to the next day. the *start* of this interval
  # will lie within the set, but the end will not. This redefines
  # "contains" to be a partial intersection, so we can prevent this
  # "off-by-1"-style issue.
  def contains(self, interval):
    return self.within(interval.start)

  def find_bounds(self, dt):
    # TBD
    raise NotImplemented

  def largestIntervalContaining(self, dt):
    if self.multi_day:
      if dt.weekday() in self.which:
        self.find_bounds(dt)
    else:
      if dt.weekday() in self.which:
        return Interval.fromDate(datetime(dt.year, dt.month, dt.day))
      else:
        return Empty()

  def within(self, dt):
    # I'll admit this is rather ugly, but the alternative is a
    # one-minute gap at the end of each event, and possible failure of
    # truly-consecutive intervals to merge.
    return dt.weekday() in self.which

  def invert(self):
    return Weekly(self.which ^ set(range(7)))

@dataclass
class Monthly(Implicit):
  """Repeats every month on the given days.

  If `month` is given, then repeats yearly during the given month,
  otherwise repeats all year.

  This will not repeat on days that are not part of the month (Feb
  29th on non-leap years, or Apr 31st).

  XXX: allow a fallback when a day doesn't exist.
  """

  days_in   : InitVar[set[int]]
  months_in : InitVar[set[int]]   = None
  months    : Dict[int, set(int)] = field(init=False)

  def __post_init__(self, days_in, months_in=None):
    self.months = {}
    if months_in:
      for m in months_in:
        dim = lastOfMonth(m, today.year).day
        self.months[m] = {dim + d if d < 0 else d for d in days_in}
    else:
      for m in range(1, 13):
        dim = lastOfMonth(m, today.year).day
        self.months[m] = {dim + d if d < 0 else d for d in days_in}

  def intersects(self, window):
    for m in range(window.start.month, window.end.month + 1):
      s = window.start.day
      e = window.end.day if window.end.day <= s else lastOfMonth(month).day
      return not self.months[m].isdisjoint(set(range(s, e)))
    else:
      return any(
        bool(self.months[m])
        for m in range(window.start.month, window.end.month + 1)
      )

  def within(self, dt):
    return (dt.month in self.months) and (dt.day in self.months[dt.month])

  # override here to prevent 1-sample gap at end of day, where the
  # ordinal advances to the next day. the *start* of this interval
  # will lie within the set, but the end will not. This redefines
  # "contains" to be a partial intersection, so we can prevent this
  # "off-by-1"-style issue.
  def contains(self, interval):
    return self.within(interval.start)

  # XXX: this will try to construct invalid dates in some situations.
  def forDays(self, year, month):
    for day in sorted(self.months[month]):
      yield Interval.fromDate(datetime(year, month, day))

  def forMonths(self, year):
    for month in sorted(self.months):
      yield from self.forDays(year, month)

  # XXX this fails on an edge case where the largest interval will be
  # clamped to the calendar year of dt, and will not "wrap around"
  # january first even if the dates would be contiguous.
  def largestIntervalContaining(self, dt):
    if self.months:
      return Explicit(list(self.forMonths(dt.year))).largestIntervalContaining(dt)
    else:
      return Explicit(list(self.forDays(dt.year, dt.month))).largestIntervalContaining(dt)

  def invert(self):
    raise NotImplemented

@dataclass
class NthWeekday(Implicit):
  """Repeats on the nth instance of the given weekday of a month.

  If `month` is given, then repeats yearly during the given month,
  otherwise repeats all year.

  This will not repeat if the nth instance of a given weekday does not
  exist.

  XXX: allow a  fallback when a day doesn't exist.
  """
  n : int
  weekday : int
  month : Option[int] = None

  def largestIntervalContaining(self, dt):
    match self.month:
      case None: month = dt.month
      case m: month = m

    return Interval.fromDate(
      nthWeekday(self.n, self.weekday, month, dt.year)
    )

  def invert(self):
    raise NotImplemented

@dataclass
class Shift(Implicit):
  """Shift a given DateSet by an arbitrary time offset.

  A positive time-delta shifts events later, while a negative
  offset shifts them earlier.

  e.g. "two days before thanksgiving" -> Offset(-2 * day, NthWeekday(4, 3, 11))
  """

  offset : timedelta
  subset : DateSet

  def intersects(self, window):
    return self.subset.intersects(window + (-self.offset))

  def span(self):
    return self.subset.span() + self.offset

  def largestIntervalContaining(self, dt):
    return self.subset.largestIntervalContaining(dt - self.offset) + self.offset

  def invert(self):
    return Shift(self.offset, self.subset.invert())

def parseDuration(time):
  """Parse a string into a timedelta.

  This can be a clock format, like 12:00, or a unit like 1m.
  """
  if time.endswith("d"):
    return int(time[:-1]) * day
  elif time.endswith("h"):
    return int(time[:-1]) * hour
  elif time.endswith("m"):
    return int(time[:-1]) * minute
  elif time.endswith("s"):
    return int(time[:-1]) * second
  elif time.endswith("w"):
    return int(time[:-1]) * week
  else:
    raise ValueError(f"Invalid Duration: {time}")

def parseDays(days):
  match days:
    case [x, "-", y]: return set(range(x, y + 1))
    case [*days]:     return set(days)

def fromJSON(decoded):
  """Quick-and-dirty DateSet expression DSL evaluator.

  Think of it like s-expressions, with the function name first. Except
  square backets and arguments separated by commas.

  Date-times are always in iso format.
  See parseDuration for time format.
  """
  match decoded:
    case int(i):
      return i
    case str(date):
      try:
        return datetime.fromisoformat(date)
      except ValueError:
        try:
          return time.fromisoformat(date)
        except ValueError:
            return parseDuration(date)
    case ["dates", *dates]:
      return Explicit([Interval.fromDate(fromJSON(d)) for d in dates])
    case ["range", start, end]:
      return Explicit([Closed(fromJSON(start), fromJSON(end))])
    case ["before", end]|["until", end]:
      return Explicit([LeftOpen(fromJSON(end))])
    case ["after", start]:
      return Explicit([RightOpen(fromJSON(start))])
    case ["never"]:
      raise ValueError("Are you sure?")
    case ["always"]:
      return Explicit([Open()])
    case ["weekly", *days]:
      return Weekly({d for d in days})
    case ["monthly", "all", *months]:
      return Monthly(set(range(1, 32)), set(months))
    case ["monthly", [*days], [*months]]:
      return Monthly(parseDays(days), set(months))
    case ["monthly", *days]:
      return Monthly(parseDays(days))
    case ["nth", n, wd]:
      return NthWeekday(n, wd)
    case ["shift", offset, ds]:
      return Shift(fromJSON(offset), fromJSON(ds))
    case ["++", period]:
      return Periodic(fromJSON(period), 1 * day)
    case ["++", period, duration]:
      return Periodic(fromJSON(period), fromJSON(duration))
    case ["++", period, duration, phase]:
      return Periodic(fromJSON(period), fromJSON(duration), fromJSON(phase))
    case ["@", time_, duration]:
      return AtTime(fromJSON(time_), fromJSON(duration))
    case ["|", *subexprs]:
      return Union([fromJSON(e) for e in subexprs])
    case ["&", *subexprs]:
      return Intersection([fromJSON(e) for e in subexprs])
    case ["~", subexpr]:
      return fromJSON(subexpr).invert()
    case ["except", a, b]:
      return Intersection([fromJSON(a), fromJSON(b).invert()])
    case ["+", a, b]:
      return fromJSON(a) + fromJSON(b)
    case ["-", a, b]:
      return fromJSON(a) - fromJSON(b)
    case ["*", a, b]:
      return fromJSON(a) * fromJSON(b)
    case ["/", a, b]:
      return fromJSON(a) / fromJSON(b)
    case e:
      raise ValueError(f"Illegal date expr: {e}")

def completion_graph(when, history, window):
  """Show the complettion history for the given time window.

  @window - the given time interval.
  @mode - the style of completion to display. One of:
          * percentage (default)
          * week
          * month
  """
  ret = ''
  for (_, completed) in when.completions(history, window):
    if completed:
      ret += '|'
    else:
      ret += 'o'
  return ret

def completed(window, node):
  when = read_date_set('schedule', node)
  history = read_completion_history(node)
  # XXX: needing to add one second to prevent interval from collapsing
  # into a single interval, which is most definitely incorrect behavior.
  #
  # write a regression test for this and and fix.
  return completion_graph(when, history, window + 1 * second)

def reverse(s):
  """Use ansi codes to invert video."""
  return f"\x1b[7m{s}\x1b[m"

def parse_window(args):
  match args:
    case ():           return Interval.fromDate(today)
    case (start,):     return Interval.fromDate(datetime.fromisoformat(start))
    case (start, end): return Interval.fromDate(datetime.fromisoformat(start), datetime.fromisoformat(end))
    case invalid:      raise ValueError("Expected one - 3 arguments")

def parse_datetime(args):
  match args:
    case []:           return today
    case ["today"]:    return today
    case ["tomorrow"]: return tomorrow
    case [iso]:        return datetime.fromisoformat(iso)
    case invalid:      raise ValueError(f"Invalid datetime: {args}")

def preview_dateset(mode, *args):
  """Parse arguments and dispatch to different preview submodes.
  """
  try:
    ds = fromJSON(json.load(sys.stdin))
  except ValueError as e:
    print("Parse Error")
    traceback.print_exception(e)
    return

  try:
    match ds.span():
      case Closed(start, end):
        print("Start:", start)
        print("End:  ", end)
  except ValueError:
    print("Start: None")
    print("End:   None")

  match mode:
    case "list":  preview_list(ds, parse_window(args))
    case "month": preview_month(ds, parse_datetime(args))
    case "week":  preview_week(ds, parse_window(args))
    case invalid: raise ValueError(f"Invalid mode: {mode}")

def preview_list(ds, window):
  """Render preview as a simple list.

  This is mainly useful for trouble-shooting, but it's also sometimes
  the best way to view a set of intervals.
  """

  def getBounds(i):
    match i:
      case Open(): return ("-∞", "∞")
      case Empty(): return ("--", "--")
      case LeftOpen(): return ("-∞", i.end)
      case RightOpen(): return (i.start, "∞")
      case Closed(): return (i.start, i.end)

  print(
    tabulate.tabulate(
      map(getBounds, ds.intervals(window)),
      headers=("Start", "End")
    )
  )

def preview_month(ds, dt):
  """Preview a DateSet using monthly calendars.

  Highlights days on which at least one interval is present.
  """

  def printDay(dt):
    if ds.within(dt):
      print(f"{reverse(f"{dt.day:2d}")} ", end='')
    else:
      print(f"{dt.day:2d} ", end='')
    if dt.weekday() == 6:
      print()

  print(f"{dt.year}-{dt.month}")
  days = daysOfMonth(dt.year, dt.month)
  first = days.__next__()
  print('Mo Tu We Th Fr Sa Su')
  print('   ' * first.weekday(), end = '')
  printDay(first)
  for day in days:
    printDay(day)
  if not dt.weekday() == 6:
    print()

def preview_week(
    ds,
    window,
    increment=hour,
    start_of_day=8 * hour,
    end_of_day=22 * hour
):
  """Preview a DateSet as a weekly calendar.

  You can make the increment as large as one day, or as small as one
  minute, but 1 hour is the default increment.
  """
  days = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

  i = startOfWeek(window.start)
  dates = count(i, day)

  while i < window.end:
    end = i + 7 * day
    xxx = []
    headers = ("Time", *(f"{name} {d.day:02d}" for (name, d) in zip(days, dates)))
    h = origin
    hh = start_of_day
    while hh < end_of_day:
      week = [[] for _ in range(8)]
      week[0] = f"{(h + hh).hour:02d}:{(h + hh).minute:02d}"
      d = i
      while d < end:
        if ds.intersects(Interval.fromStartDuration(d + hh, increment)):
          week[d.weekday() + 1] = reverse(' ' * 7)
        else:
          week[d.weekday() + 1] = ' ' * 7
        d += day
      xxx.append(week)
      hh += increment
    print(tabulate.tabulate(xxx, headers = headers, tablefmt='simple_outline'))
    i += 7 * day

def agenda(
    # date=None,
    # interval=15 * minute,
    # start_of_day=8 * hour,
    # end_of_day=22 * hour
    *selection
):
  """Print agenda view for a single day.

  This will show scheduled and unscheduled activity for the given
  input set.
  """
  selected = set(selection)

  def show_gloss(id):
    """Render task gloss, highlighting selected nodes."""
    gloss = graph.task_gloss(id)
    if id in selected:
      return reverse(gloss)
    else:
      return gloss

  dt = datetime.today()
  interval = 15 * minute
  start_of_day=8 * hour
  end_of_day=22 * hour
  todo = []
  scheduled = {}
  habits = {}
  for id in graph.read_ids():
    match classify_node(id):
      case "unscheduled": todo.append(id)
      case "event":
        scheduled[id] = (show_gloss(id), read_date_set('schedule', id))
      case "habit":
        habits[id] = (
          show_gloss(id),
          read_date_set('schedule', id),
          read_completion_history(id)
        )

  # build a mapping from time blocks to events.
  # start = datetime(dt.year, dt.month, dt.day) + start_of_day
  # end = datetime(dt.year, dt.month, dt.day) + end_of_day
  # time_map = {}
  # for cur in Closed(start, end).sequence(interval):
  #   timestr = f"{cur.start.hour:02d}:{cur.start.minute:02d}"
  #   for (id, (_, when)) in scheduled.items():
  #     if when.intersects(cur):
  #       graph.dict_append(time_map, timestr, id)
  # width = int(os.getenv("COLUMNS", "80"))
  # schedule = []
  horizon = Interval.fromDate(dt)
  intervals = []
  for (id, (gloss, when)) in scheduled.items():
    intervals.extend((gloss, i) for i in when.intervals(horizon))

  print("Agenda")
  intervals.sort(key=lambda x: x[1].start)
  for (gloss, interval) in intervals:
    timestr = f"{interval.start.hour:02d}:{interval.start.minute:02d}"
    print(timestr, gloss)
  print()

  # format the time map into an agenda view
  # print("Agenda")
  # for hour, items in time_map.items():
  #   if items:
  #     schedule.append((hour, "\n".join(map(graph.task_gloss, items))))
  # print(tabulate.tabulate(schedule))
  # print()

  # build habit graphs
  print("Habits")
  print(tabulate.tabulate(
    ((gloss, completion_graph(ds, hist, Closed(dt - 28 * day, dt)))
    for (gloss, ds, hist)
    in habits.values())
  ))
  print()

def datum_read_json(datum, id):
  """Read the given datum and try to decode it as JSON."""
  return json.load(open(graph.datum_path(datum, id)))

def read_date_set(datum, id):
  """Read the given datum and try to construct a DateSet from it.

  For now this uses fromJSON to parse the ad-hoc DateSet DSL.
  """
  return fromJSON(datum_read_json(datum, id))

def read_completion_history(id):
  """Read the `completed` datum into a `Set[datetime]`.

  These are assumed to be in iso format, one per line.
  """
  try:
    return set(
      map(lambda x: datetime.fromisoformat(x).replace(tzinfo=None),
          map(str.strip, graph.datum_open("completed", id))))
  except ValueError:
    return set()

def classify_node(id):
  """Determine node type from its data.

  Nodes can be events, tasks, habits, or unscheduled.
  """
  if graph.has('schedule', id):
    if graph.has('completed', id):
      return "habit"
    else:
      return "event"
  else:
    return "unscheduled"

def is_scheduled(id):
  """True if a node's active / actionable status is determined by the scheduler.
  """
  match classify_node(id):
    case "unscheduled": return False
    case _:             return True

def is_unscheduled(id):
  """True if a node's active / actionable status is not determined solely by the task state.
  """
  return not is_scheduled(id)

def is_eternal(id):
  """True if a node has a schedule with no end date."""
  return is_scheduled(id) and not read_date_set("schedule", id).span().is_finite()

def is_temporal(id):
  """True if a task has a schedule with an end date."""
  return is_scheduled(id) and read_date_set("schedule", id).span().is_finite()

def is_complete(window, id):
  """Keep nodes that are completed.

  True if a node is in state DONE, or scheduled nodes with a completion window.
  """
  if graph.task_state(id) == "DONE":
    return True
  elif is_scheduled(id) and graph.has("completed", id):
    when = read_date_set("schedule", id)
    history = read_completion_history(id)
    return when.is_complete(history, window)
  else:
    return False

def is_incomplete(window, id):
  """Keep nodes that have not been completed."""
  if graph.task_state(id) == "DONE":
    return False
  elif is_scheduled(id) and graph.has("completed", id):
    when = read_date_set("schedule", id)
    history = read_completion_history(id)
    return not when.is_complete(history, window)
  else:
    return True

def in_progress(dt, id):
  try:
    if is_scheduled(id):
      return read_date_set("schedule", id).within(dt)
    else:
      # XXX: this will return true for anything that isn't scheduled,
      # which is wrong. input must be pre-filtered to tasks.
      return True
  except BaseException:
    debug(f"Invalid Schedule Expr: {id}")

def is_upcoming(window, id):
  """True if an activity will become active within the given window.

  The default window is the current day, but arbitrary intervals are
  accepted. If a duration is given instead, then it is relative to the
  current time.
  """
  raise NotImplemented

def is_due(window, tasks):
  """True if a task or habit's completion window will end within the
  given window.

  Defaults and arguments are the same as for `is_upcoming`.
  """
  raise NotImplemented

def parse_datetime(args):
  """Parse a list of strings into a date time.

  This supports convenient shorthands for dates.
  """

  days = {
    "mo": 0, "tu": 1, "we": 2, "th": 3, "fr": 4, "sa": 5, "su": 6,
    "mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6,
    "monday": 0,
    "tuesday": 1,
    "wednesday": 2,
    "thursday": 3,
    "friday": 4,
    "saturday": 5,
    "sunday": 6,
  }

  match args:
    case []:
      return today
    case ["yesterday"]:
      return startOfDay(today - day)
    case ["tomorrow"]:
      return startOfDay(today + day)
    case ["this", dayName] | [dayName] if dayName.lower() in days:
      d = dayName.lower()
      if d in days:
        return startOfWeek(today) + days[d]
      else:
        return startOfWeek(today) + int(d)
    case ["last", dayName]:
      d = dayName.lower()
      if d in days:
        return startOfWeek(today) - 7 * day + days[dayName.lower()]
      else:
        return startOfWeek(today) - 7 * day + int(d)
    case ["next", dayName]:
      d = dayName.lower()
      if d in days:
        return startOfWeek(today) + 7 * day + days[dayName.lower()]
      else:
        return startOfWeek(today) + 7 * day + int(d)
    case [iso]:
      return datetime.fromisoformat(iso)

# XXX: rename and marge with parse_window
def window_args(*args):
  """Parse a list of strings into an Interval.

  This supports some conveninet shorthands like "past", "until", and "since".
  """

  match args:
    case []:
      return Interval.fromDate(today)
    case ["until", *end]:
      return LeftOpen(parse_datetime(end))
    case ["past", "week"]:
      return Closed(
        today - 7 * day,
        endOfDay(today)
      )
    case ["past", "fortnight"]:
      return Closed(
        today - 14 * day,
        endOfDay(today)
      )
    case ["past", "month"]:
      return Closed(
        prevMonth(today.month).replace(day=today.day),
        endOfDay(today),
      )
    case ["past", duration]:
      return Closed(
        today - parseDuration(duration),
        today
      )
    case ["this", "week"]:
      return Closed(
        startOfWeek(today),
        today
      )
    case ["since", *start]:
      return RightOpen(parse_datetime(start))
    case [s]:
      try:
        return parseDuration(str)
      except ValueError:
        return Interval.fromDate(datetime.fromisoformat(s))
    case [start, end]|[start, "-", end]:
      return Interval.fromDate(
        datetime.fromisoformat(start),
        datetime.fromisoformat(end)
      )
    case _: raise ValueError("Invalid window: {args}")

def filter_window(f, *args):
  return graph.filter_nodes(f, window_args(*args))

def filter_datetime(f, *args):
  match args:
    case [str]:
      return graph.filter_nodes(f, datetime.fromisoformat(str).replace(tzinfo=None))
    case []:
      return graph.filter_nodes(f, now)
    case invalid:
      raise ValueError("Invalid arguments: {args}")

def foreach(f, *args):
  """Call f(args, node) on each node read from stdin, and print the result.

  This is a helper function to make it easier to extend the
  command-line interface with ad-hoc subcommands, and a candidate to
  be moved to a utility library.
  """
  for node in graph.read_ids():
    print(f(*args, node))

if __name__ == "__main__":
  match sys.argv[1:]:
    case ["is_upcoming", *args]:   filter_window(is_upcoming, *args)
    case ["is_complete", *args]:   filter_window(is_complete, *args)
    case ["is_incomplete", *args]: filter_window(is_incomplete, *args)
    case ["is_scheduled"]:         graph.filter_nodes(is_scheduled)
    case ["is_unscheduled"]:       graph.filter_nodes(is_unscheduled)
    case ["in_progress", *args]:   filter_datetime(in_progress, *args)
    case ["is_due", *args]:        filter_window(is_due,      *args)
    case ["complete", *args]:      complete(*args)
    case ["completed", *args]:     foreach(completed, window_args(*args))
    case ["schedule"]:             foreach(read_date_set, 'schedule')
    case ["deadline"]:             foreach(read_date_set, 'deadline')
    case ["classify"]:             foreach(classify_node)
    case ["preview", *args]:       preview_dateset(*args)
    case ["validate"]:             print(fromJSON(json.load(sys.stdin)))
    case ["agenda", *args]:        agenda(*args)
    case invalid:
      raise ValueError("Invalid Command:", invalid)
