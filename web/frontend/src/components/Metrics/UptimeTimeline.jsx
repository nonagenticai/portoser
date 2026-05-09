import React, { useState } from 'react'
import { ZoomIn, ZoomOut } from 'lucide-react'
import clsx from 'clsx'

/**
 * UptimeTimeline Component
 * Visual timeline showing service uptime/downtime with colored segments
 */
function UptimeTimeline({ events, timeRange = '7d', onTimeRangeChange }) {
  const [hoveredEvent, setHoveredEvent] = useState(null)
  const [zoom, setZoom] = useState(1)

  const timeRanges = [
    { value: '24h', label: '24 Hours' },
    { value: '7d', label: '7 Days' },
    { value: '30d', label: '30 Days' }
  ]

  if (!events || events.length === 0) {
    return (
      <div className="flex items-center justify-center h-32 bg-gray-50 rounded-lg border border-gray-200">
        <p className="text-gray-500">No uptime events available</p>
      </div>
    )
  }

  // Calculate time range
  const now = new Date()
  const startTime = new Date(now)

  switch (timeRange) {
    case '24h':
      startTime.setHours(now.getHours() - 24)
      break
    case '7d':
      startTime.setDate(now.getDate() - 7)
      break
    case '30d':
      startTime.setDate(now.getDate() - 30)
      break
  }

  const totalDuration = now - startTime

  // Group events into segments
  const segments = buildSegments(events, startTime, now)

  return (
    <div className="space-y-4">
      {/* Header with controls */}
      <div className="flex items-center justify-between">
        <h3 className="text-lg font-semibold text-gray-900">Uptime Timeline</h3>

        <div className="flex items-center space-x-2">
          {/* Time Range Selector */}
          <div className="flex bg-gray-100 rounded-lg p-1">
            {timeRanges.map(range => (
              <button
                key={range.value}
                onClick={() => onTimeRangeChange && onTimeRangeChange(range.value)}
                className={clsx(
                  'px-3 py-1.5 text-sm font-medium rounded-md transition-colors',
                  {
                    'bg-white text-blue-600 shadow-sm': timeRange === range.value,
                    'text-gray-600 hover:text-gray-900': timeRange !== range.value
                  }
                )}
              >
                {range.label}
              </button>
            ))}
          </div>

          {/* Zoom controls */}
          <div className="flex border border-gray-300 rounded-lg overflow-hidden">
            <button
              onClick={() => setZoom(Math.max(1, zoom - 0.5))}
              className="p-2 hover:bg-gray-100 transition-colors border-r border-gray-300"
              title="Zoom out"
            >
              <ZoomOut className="w-4 h-4" />
            </button>
            <button
              onClick={() => setZoom(Math.min(3, zoom + 0.5))}
              className="p-2 hover:bg-gray-100 transition-colors"
              title="Zoom in"
            >
              <ZoomIn className="w-4 h-4" />
            </button>
          </div>
        </div>
      </div>

      {/* Timeline */}
      <div className="bg-white border border-gray-200 rounded-lg p-4 overflow-x-auto">
        <div style={{ minWidth: `${100 * zoom}%` }}>
          {/* Time markers */}
          <div className="flex justify-between text-xs text-gray-500 mb-2">
            {generateTimeMarkers(startTime, now, 6).map((time, i) => (
              <span key={i}>{formatTimeMarker(time, timeRange)}</span>
            ))}
          </div>

          {/* Timeline bar */}
          <div className="relative h-12 bg-gray-100 rounded-lg overflow-hidden">
            {segments.map((segment, index) => {
              const startPercent = ((segment.start - startTime) / totalDuration) * 100
              const widthPercent = ((segment.end - segment.start) / totalDuration) * 100

              return (
                <div
                  key={index}
                  className={clsx(
                    'absolute h-full cursor-pointer transition-all hover:opacity-80',
                    getSegmentColor(segment.status)
                  )}
                  style={{
                    left: `${startPercent}%`,
                    width: `${widthPercent}%`
                  }}
                  onMouseEnter={() => setHoveredEvent(segment)}
                  onMouseLeave={() => setHoveredEvent(null)}
                  title={`${segment.status} - ${formatDuration((segment.end - segment.start) / 1000)}`}
                />
              )
            })}

            {/* Current time indicator */}
            <div
              className="absolute top-0 bottom-0 w-0.5 bg-blue-600 z-10"
              style={{ right: 0 }}
            >
              <div className="absolute -top-2 -left-1 w-3 h-3 bg-blue-600 rounded-full"></div>
            </div>
          </div>

          {/* Event markers */}
          <div className="relative h-8 mt-2">
            {events
              .filter(event => {
                const eventTime = new Date(event.timestamp)
                return eventTime >= startTime && eventTime <= now
              })
              .map((event, index) => {
                const eventTime = new Date(event.timestamp)
                const position = ((eventTime - startTime) / totalDuration) * 100

                return (
                  <div
                    key={index}
                    className="absolute top-0"
                    style={{ left: `${position}%` }}
                    onMouseEnter={() => setHoveredEvent({ ...event, isMarker: true })}
                    onMouseLeave={() => setHoveredEvent(null)}
                  >
                    <div
                      className={clsx(
                        'w-2 h-2 rounded-full cursor-pointer transform -translate-x-1',
                        getEventMarkerColor(event.event_type)
                      )}
                    />
                  </div>
                )
              })}
          </div>
        </div>

        {/* Tooltip */}
        {hoveredEvent && (
          <div className="mt-4 p-3 bg-gray-50 rounded-lg border border-gray-200">
            {hoveredEvent.isMarker ? (
              // Event marker tooltip
              <div>
                <div className="flex items-center space-x-2 mb-1">
                  <div
                    className={clsx('w-2 h-2 rounded-full', getEventMarkerColor(hoveredEvent.event_type))}
                  />
                  <span className="font-semibold text-gray-900 capitalize">
                    {hoveredEvent.event_type.replace('_', ' ')}
                  </span>
                </div>
                <div className="text-sm text-gray-600">
                  {new Date(hoveredEvent.timestamp).toLocaleString()}
                </div>
                {hoveredEvent.details && (
                  <div className="text-sm text-gray-700 mt-2">
                    {hoveredEvent.details}
                  </div>
                )}
              </div>
            ) : (
              // Segment tooltip
              <div>
                <div className="flex items-center space-x-2 mb-1">
                  <div className={clsx('w-3 h-3 rounded', getSegmentColor(hoveredEvent.status))} />
                  <span className="font-semibold text-gray-900 capitalize">
                    {hoveredEvent.status}
                  </span>
                </div>
                <div className="text-sm text-gray-600">
                  Duration: {formatDuration((hoveredEvent.end - hoveredEvent.start) / 1000)}
                </div>
                <div className="text-sm text-gray-500 mt-1">
                  {new Date(hoveredEvent.start).toLocaleString()} - {new Date(hoveredEvent.end).toLocaleString()}
                </div>
              </div>
            )}
          </div>
        )}
      </div>

      {/* Legend */}
      <div className="flex items-center justify-center space-x-6 text-sm">
        <div className="flex items-center space-x-2">
          <div className="w-4 h-4 bg-green-500 rounded"></div>
          <span className="text-gray-700">Up</span>
        </div>
        <div className="flex items-center space-x-2">
          <div className="w-4 h-4 bg-red-500 rounded"></div>
          <span className="text-gray-700">Down</span>
        </div>
        <div className="flex items-center space-x-2">
          <div className="w-4 h-4 bg-yellow-500 rounded"></div>
          <span className="text-gray-700">Recovering</span>
        </div>
      </div>
    </div>
  )
}

/**
 * Build timeline segments from events
 */
function buildSegments(events, startTime, endTime) {
  const segments = []
  let currentStatus = 'up'
  let segmentStart = startTime

  // Sort events by timestamp
  const sortedEvents = [...events].sort((a, b) =>
    new Date(a.timestamp) - new Date(b.timestamp)
  )

  sortedEvents.forEach(event => {
    const eventTime = new Date(event.timestamp)

    if (eventTime < startTime) {
      // Event is before our time range, just update status
      currentStatus = getStatusFromEvent(event.event_type)
      return
    }

    if (eventTime > endTime) {
      return
    }

    // Create segment for previous status
    segments.push({
      start: segmentStart,
      end: eventTime,
      status: currentStatus
    })

    // Update for next segment
    currentStatus = getStatusFromEvent(event.event_type)
    segmentStart = eventTime
  })

  // Final segment to current time
  segments.push({
    start: segmentStart,
    end: endTime,
    status: currentStatus
  })

  return segments
}

/**
 * Get status from event type
 */
function getStatusFromEvent(eventType) {
  switch (eventType) {
    case 'start':
    case 'recovery':
      return 'up'
    case 'stop':
    case 'failure':
      return 'down'
    default:
      return 'up'
  }
}

/**
 * Get color class for segment
 */
function getSegmentColor(status) {
  switch (status) {
    case 'up':
      return 'bg-green-500'
    case 'down':
      return 'bg-red-500'
    case 'recovering':
      return 'bg-yellow-500'
    default:
      return 'bg-gray-500'
  }
}

/**
 * Get color class for event marker
 */
function getEventMarkerColor(eventType) {
  switch (eventType) {
    case 'start':
      return 'bg-green-600'
    case 'stop':
      return 'bg-gray-600'
    case 'failure':
      return 'bg-red-600'
    case 'recovery':
      return 'bg-yellow-600'
    default:
      return 'bg-blue-600'
  }
}

/**
 * Generate time markers for timeline
 */
function generateTimeMarkers(start, end, count) {
  const markers = []
  const interval = (end - start) / (count - 1)

  for (let i = 0; i < count; i++) {
    markers.push(new Date(start.getTime() + interval * i))
  }

  return markers
}

/**
 * Format time marker based on time range
 */
function formatTimeMarker(time, timeRange) {
  if (timeRange === '24h') {
    return time.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
  }
  return time.toLocaleDateString([], { month: 'short', day: 'numeric' })
}

/**
 * Format duration
 */
function formatDuration(seconds) {
  const hours = Math.floor(seconds / 3600)
  const minutes = Math.floor((seconds % 3600) / 60)

  if (hours > 24) {
    const days = Math.floor(hours / 24)
    return `${days}d ${hours % 24}h`
  }

  if (hours > 0) {
    return `${hours}h ${minutes}m`
  }

  return `${minutes}m`
}

export default UptimeTimeline
