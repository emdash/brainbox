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
from dataclasses import dataclass

import itertools
import json
import sys

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

# the length of the day in seconds, for our purposes
ticks = 86400

def debug(*args):
  print(*args)
  return args[-1]

def superordinal(x):
  """Like datetime.toordinal, but in seconds."""
  match x:
    case datetime() as dt:
      return dt.second           \
        +  60 * (dt.minute       \
        + (60 * (dt.hour         \
        + (24 * dt.toordinal()))))
    case timedelta() as td:
      return td.seconds + 60 * 60 * 24 * td.days
    case date() as d:
      return d.toordinal() * 86400
    case invalid:
      raise ValueError(f"Cannot convert {invalid} to superordinal")

def firstOfMonth(month=today.month, year=today.year):
  """Return the date on which the given month begins."""
  return datetime(year, month, 1)

def startOfWeek(day=today.day, month=today.month, year=today.year):
  """Return the monday which begins the week containing the given day."""
  dt = datetime(year, month, day)
  return dt - timedelta(days=dt.weekday())

def daysOfMonth(month=today.month, year=today.year):
  """Yields all the days of the given month, in order."""
  dt = firstOfMonth(year, month)
  if dt.month == 12:
    end = datetime(dt.year + 1, 1, 1)
  else:
    end = datetime(dt.year, dt.month + 1, 1)
  while dt < end:
    yield dt.day
    dt += 1 * day

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

@dataclass
class Interval:
  """The time between two timestamps, or a start timestamp and duration.

  We can do various operations on intervals, including tests for
  containment and intersection, and subdividing in various ways.
  """

  start : datetime
  end : datetime

  @property
  def duration(self):
    """A time delta from the start of the interval.

    This is assumed to be positive.
    """
    return self.end - self.start

  @classmethod
  def fromStartDuration(self, start, duration):
    "Create an interval from a timestamp and duration."
    return Interval(start, start + duration)

  @classmethod
  def fromDate(self, dt, end=None):
    """Construct an interval that spans a date or date range."""
    match end:
      case None: return Interval(startOfDay(dt), endOfDay(dt))
      case end:  return Interval(startOfDay(dt), endOfDay(end))

  @classmethod
  def sequence(self, start, duration, period=None, phase=0):
    """Yields an infinite sequence of evenly-spaced intervals."""
    if period is None:
      period = duration

    assert isinstance(datetime, start)
    assert isinstance(timedelta, duration)
    assert isinstance(timedelta, period)
    assert period > 0
    assert duration > 0
    assert phase >= 0
    assert phase < period

    i = start
    while True:
      yield Interval.fromStartDuration(i + phase, duration)
      i += period

  @classmethod
  def mergeConsecutive(self, intervals):
    """Yields intervals, merging runs of intersecting intervals."""
    next = None
    for i in intervals:
      match next:
        case None:
          next = i
        case next:
          if next.intersects(i):
            next = next.span(i)
          else:
            yield next
            next = i
    if i:
      yield i

  def within(self, timestamp):
    """True if timestamp occurs on or before start, and strictly before end.

    This is so that back-to-events will not supriously register as
    overlapping.
    """
    return self.start <= timestamp < self.end

  def intersects(self, interval):
    """True if any part of this interval overlaps with the other interval."""
    # These are the cases that match --
    #     [ss---------------se]
    #----------------------------------
    #  [is-----------------------ie]
    #  [is----------ie]
    #         [is--------ie]
    #                [is----------ie]

    points = [
      (self.start,     "ss"),
      (self.end,       "se"),
      (interval.start, "is"),
      (interval.end,   "ie")
    ]
    points.sort(key = lambda x: x[0])

    match [p[1] for p in points]:
      case ["is", "ss", "se", "ie"]: return True
      case ["is", "ss", "ie", "se"]: return True
      case ["ss", "is", "ie", "se"]: return True
      case ["ss", "is", "se", "ie"]: return True
      case _:                        return False

  def subdivide(self, interval):
    """Subdivide this interval evenly into n subintervals"""
    i = 0
    start = self.start
    n = self.duration // interval
    while start < self.end:
      end = start + interval
      yield Interval(start, end)
      start = end

  def span(self, interval):
    """Return the smallest interval containg self and interval."""
    return Interval(
      min(self.start, interval.start),
      max(self.end, interval.end)
    )

  def intersection(self, interval):
    """Return the portion of two overlapping intervals which intersects.

    This will throw `ValueError` if the two intervals are not overlapping.
    """
    if self.intersects(interval):
      return Interval(
        max(self.start, interval.start),
        min(self.end, interval.end)
      )
    else:
      raise ValueError("Intervals do not Overlap")

  def ordinals(self):
    """An iterator over the julian ordinals which this interval intersects.

    This will always yield at least one value.
    """
    return range(self.start.toordinal(), self.end.toordinal() + 1, 1)

@dataclass
class DateSet:
  """Represents when an event can happen.

  We can ask a date set whether or not an arbitrary interval
  intersects it, and we can ask for the set of intervals contained
  within the date set down to some precision.

  A date set can be finite or infinite. For finite date sets, we can
  find the span.

  """

  def intersects(window):
    """True if window coincides with any portion"""
    raise NotImplemented

  def is_finite(self):
    """True if this date set is finite."""
    raise NotImplemented

  def span(self):
    """Returns the smallest interval which contains the entire set."""
    raise NotImplemented

  def intervals(self, window):
    """Return an ordered sequence of intervals which intersect `window`."""
    raise NotImplemented

@dataclass
class Explicit(DateSet):
  """An explicit list of intervals.

  Intersection is defined in terms of `intervals`, returning true if any
  of the subintervals intersects.
  """

  given : List[Interval]

  def is_finite(self):
    return True

  def span(self):
    def _spanRec(list):
      match given:
        case []: raise ValueError("Empty")
        case [x]: return x
        case [first, *rest]: return first.span(span_rec(rest))
    return spanRec(self.given)

  def intersects(self, window):
    return any(i.intersects(window) for i in self.intervals(window))

  def intervals(self, window):
    for i in Interval.mergeConsecutive(self.given):
      if i.intersects(window):
        yield i

@dataclass
class Implicit(DateSet):
  """Base class for types defining intervals via an implicit function.

  `intervals` is defined in terms of `intersection`, sampling the
  `intersection` at some precision, and then merging the result.
  """

  def is_finite(self):
    return False

  def implicit(self, window, resolution=minute):
    return filter(self.intersects, Interval.sequence(window.start, resolution))

  def intervals(self, window, resolution=minute):
    return takewhile(
      window.intersects,
      Interval.mergeConsecutive(self.implicit(window, resolution))
    )

@dataclass
class Not:
  """The logical inverse of the given subexpression.

  E.g. Not(AtTime(12:00, 13:00)) would be all day *except* from noon
  to 13:00. Not(Weekly({5, 6})) would be every day *except* weekends.
  """

  subexpr : DateSet

  def intersects(self, window):
    return not self.subexpr.intersects(window)

@dataclass
class Compound(Implicit):
  """Base class for date sets which are composed of arbitrary subsets."""
  subsets: set[DateSet]

  def span(self):
    if self.is_finite():
      spans = [span(e) for e in self.subsets]
      starts = [s.start for s in spans]
      ends = [s.end for s in spans]
      return Interval(min(starts), max(ends))
    else:
      raise ValueError("Expr is not Finite")

@dataclass
class Union(Compound):
  """Take the union of arbitrary subsets.

  If all the subsets are finite, then the union over them is finite.
  """
  def is_finite(self):
    return all(e.is_finite() for e in self.subsets)

  def intersects(self, interval):
    return any(e.intersects(interval) for e in self.subsets)

@dataclass
class Intersection(Compound):
  """Take the intersection of two arbitrary subsets.

  If any of the subsets is finite, then the intersection is finite.
  """
  def is_finite(self):
    return any(e.is_finite() for e in self.subsets)

  def intersects(self, interval):
    return all(e.intersects(interval) for e in self.subsets)

@dataclass
class Periodic(Implicit):
  """An infinite set of intervals repeating evenly at arbitrary times."""

  period   : timedelta               # defines time between intervals
  duration : timedelta = 1 * day     # length of the interval.
  phase    : timedelta = timedelta() # shifts start time by up to one period

  def __post_init__(self):
    assert self.duration <= self.period
    assert self.phase < self.period

  def intervals(self, interval):
    period   = superordinal(self.period)
    duration = superordinal(self.duration)
    phase    = superordinal(self.phase)
    start    = superordinal(interval.start) % period
    end      = superordinal(interval.end)   % period
    return Interval(phase, phase + duration).intersects(Interval(start, end))

@dataclass
class AtTime(Implicit):
  """Repeat at a particular time, for a particular duration every day.

  To schedule an event at multiple times, take the union.
  """
  start    : time
  duration : timedelta

  def __post_init__(self):
    assert self.duration > timedelta()
    # assert (self.start + self.duration) < (1 * day)

  def intersects(self, interval):
    return Interval.fromStartDuration(
      datetime(
        interval.start.year,
        interval.start.month,
        interval.start.day,
        self.start.hour,
        self.start.minute,
        self.start.second,
        self.start.microsecond
      ),
      duration
    ).intersects(interval)

@dataclass
class OrdinalSet(Implicit):
  """A date set based on day patterns.

  This implements weekday and other day-based patterns.

  You can think of this as consisting of an arbitrary, infinite
  sequence of full-day intervals.

  If you also wish to schedule at a particular time, take the
  intersection with a

  """
  def is_finite(self):
    return False

  def test(self, date):
    pass

  def intersects(self, interval):
    return any(self.test(o) for o in interval.ordinals())

@dataclass
class Weekly(OrdinalSet):
  """An arbitrary pattern that repeats every N days"""
  which : set[int]

  def __post_init__(self):
    assert all(0 <= day < 7 for day in self.which)

  def test(self, ordinal):
    return (ordinal % 7) in self.which

@dataclass
class Monthly(Implicit):
  days : set[int]

  def intersects(self, window):
    dt = window.start
    while dt < window.end:
      if dt.day in self.days:
        return True
    return False

@dataclass
class NthWeekday(Implicit):
  n : int
  weekday : int

  def intersects(self, window):
    return window.intersects(nthWeekday(
      self.n,
      self.weekday,
      window.month,
      window.year
    ))

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
    case ["explicit", *dates]:
      return Explicit([Interval.fromDate(fromJSON(d)) for d in dates])
    case ["weekly", *days]:
      return Weekly({d for d in days})
    case ["monthly", *days]:
      return Monthly({d for d in days})
    case ["nth", n, wd]:
      return NthWeekday(n, wd)
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
      return Not(fromJSON(subexpr))
    case ["except", a, b]:
      return Intersection([fromJSON(a), Not(fromJSON(b))])
    case ["+", a, b]:
      return fromJSON(a) + fromJSON(b)
    case ["-", a, b]:
      return fromJSON(a) - fromJSON(b)
    case ["*", a, b]:
      return fromJSON(a) * fromJSON(b)
    case ["/", a, b]:
      return fromJSON(a) / fromJSON(b)
    case e:
      raise ValueError("Illegal date expr: {e}")

@dataclass
class Event:
  """A calendar item, which occurs at a particular (possibly repeating) time.

  @id     - the graph node associated with this item
  @notify - how long before the next occurrence to remind the user.
  """
  id: str
  reminders: list[timedelta]
  when : set[timedelta]

@dataclass
class Task(Event):
  """An event with a completion requirement and history."""
  completed : Set[datetime]

@dataclass
class Habit(Task):
  """A recurring task which progresses towards some goal.
  """
  goal : str
  progress : str

def display_month(highlight, month=today.month, year=today.year):
  """Display a text calendar with matching dates highlighted"""
  days = daysOfMonth(dt.year, dt.month)
  first = days.next()
  print('Mo Tu We Th Fr Sa Su')
  print('   ' * first.weekday(), end = '')
  for d in days:
    cell = f"{d.day:02d} "
    if Interval.fromDate(d).intersects(highlight):
      print(reverse(cell), end='')
    else:
      print(cell, end='')
    if d.weekday() == 6:
      print()
    d += 1 * day
  print()

def display_agenda(events, start=today, end=today + 7 * day):
  """Display a formatted agend view"""
  pass

def display_completion_calendar(habit, window):
  pass

def display_habit_graph(habitx, window):
  pass

def get_events():
  """Read an event list from stdin"""
  for line in sys.stdin():
    match line.split('|'):
      case [id, pattern]:
        yield Event(id, DateSet.parsePattern(pattern), set([]))
      case [id, pattern, reminders]:
        yield Event(
          id,
          DateSet.parsePattern(pattern),
          map(datetime.fromisoformat, set(reminders.split(',')))
        )
      case invalid:
        raise ValueError(f"Invalid line: {invalid}")

def is_upcoming(events, horizon=tomorrow):
  return filter(event_is_upcoming(horizon), events)

def is_overdue(tasks, deadline=today):
  return filter(task_is_due(deadline), tasks)

def is_ontime(tasks, deadline=today):
  return filter(task_is_ontime(deadline), tasks)

def is_ontrack(habits):
  pass
