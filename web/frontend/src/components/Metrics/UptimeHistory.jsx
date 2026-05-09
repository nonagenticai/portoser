import React, { useState } from 'react'
import { Filter, Download, ChevronDown } from 'lucide-react'
import { useUptimeEvents } from '../../hooks/useUptime'
import clsx from 'clsx'

/**
 * UptimeHistory Component
 * List of uptime events in chronological order with filtering and export
 */
function UptimeHistory({ serviceName, machineName }) {
  const [eventTypeFilter, setEventTypeFilter] = useState(null)

  const { events, loading, error, hasMore, loadMore } = useUptimeEvents(
    serviceName,
    machineName,
    {
      limit: 50,
      eventType: eventTypeFilter,
      realTime: true
    }
  )

  const handleExport = () => {
    if (!events || events.length === 0) return

    // Convert to CSV
    const headers = ['Timestamp', 'Event Type', 'Duration', 'Details']
    const rows = events.map(event => [
      new Date(event.timestamp).toISOString(),
      event.event_type,
      event.duration ? `${event.duration}s` : '',
      event.details || ''
    ])

    const csv = [
      headers.join(','),
      ...rows.map(row => row.map(cell => `"${cell}"`).join(','))
    ].join('\n')

    // Download
    const blob = new Blob([csv], { type: 'text/csv' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `${serviceName}_${machineName}_uptime_events_${Date.now()}.csv`
    a.click()
    URL.revokeObjectURL(url)
  }

  const eventTypes = [
    { value: null, label: 'All Events' },
    { value: 'start', label: 'Start' },
    { value: 'stop', label: 'Stop' },
    { value: 'failure', label: 'Failure' },
    { value: 'recovery', label: 'Recovery' }
  ]

  return (
    <div className="space-y-4">
      {/* Header with controls */}
      <div className="flex items-center justify-between">
        <h3 className="text-lg font-semibold text-gray-900">Event History</h3>

        <div className="flex items-center space-x-3">
          {/* Event type filter */}
          <div className="relative">
            <select
              value={eventTypeFilter || ''}
              onChange={(e) => setEventTypeFilter(e.target.value || null)}
              className="appearance-none bg-white border border-gray-300 rounded-lg px-4 py-2 pr-10 text-sm font-medium text-gray-700 hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-blue-500"
            >
              {eventTypes.map(type => (
                <option key={type.value || 'all'} value={type.value || ''}>
                  {type.label}
                </option>
              ))}
            </select>
            <Filter className="absolute right-3 top-1/2 transform -translate-y-1/2 w-4 h-4 text-gray-500 pointer-events-none" />
          </div>

          {/* Export button */}
          <button
            onClick={handleExport}
            disabled={!events || events.length === 0}
            className="flex items-center space-x-2 px-3 py-2 bg-gray-100 hover:bg-gray-200 rounded-lg transition-colors text-sm font-medium text-gray-700 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            <Download className="w-4 h-4" />
            <span>Export CSV</span>
          </button>
        </div>
      </div>

      {/* Error message */}
      {error && (
        <div className="p-4 bg-red-50 border border-red-200 rounded-lg text-red-700">
          Error loading events: {error}
        </div>
      )}

      {/* Events list */}
      <div className="space-y-3">
        {loading && events.length === 0 ? (
          // Loading skeleton
          <div className="space-y-3">
            {[1, 2, 3, 4, 5].map(i => (
              <div key={i} className="animate-pulse bg-gray-100 rounded-lg p-4 h-20"></div>
            ))}
          </div>
        ) : events.length === 0 ? (
          // Empty state
          <div className="text-center py-12 text-gray-500">
            <p>No events found</p>
          </div>
        ) : (
          // Event cards
          events.map((event, index) => (
            <EventCard key={index} event={event} />
          ))
        )}

        {/* Load more button */}
        {hasMore && (
          <button
            onClick={loadMore}
            disabled={loading}
            className="w-full flex items-center justify-center space-x-2 py-3 border border-gray-300 rounded-lg hover:bg-gray-50 transition-colors text-sm font-medium text-gray-700 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            <span>{loading ? 'Loading...' : 'Load More'}</span>
            <ChevronDown className="w-4 h-4" />
          </button>
        )}
      </div>
    </div>
  )
}

/**
 * EventCard Component
 * Individual event card showing event details
 */
function EventCard({ event }) {
  const getEventBadgeColor = (eventType) => {
    switch (eventType) {
      case 'start':
        return 'bg-green-100 text-green-700 border-green-200'
      case 'stop':
        return 'bg-gray-100 text-gray-700 border-gray-200'
      case 'failure':
        return 'bg-red-100 text-red-700 border-red-200'
      case 'recovery':
        return 'bg-yellow-100 text-yellow-700 border-yellow-200'
      default:
        return 'bg-blue-100 text-blue-700 border-blue-200'
    }
  }

  const formatEventType = (eventType) => {
    return eventType.charAt(0).toUpperCase() + eventType.slice(1).replace('_', ' ')
  }

  const formatDuration = (seconds) => {
    if (!seconds) return null

    const hours = Math.floor(seconds / 3600)
    const minutes = Math.floor((seconds % 3600) / 60)
    const secs = seconds % 60

    const parts = []
    if (hours > 0) parts.push(`${hours}h`)
    if (minutes > 0) parts.push(`${minutes}m`)
    if (secs > 0 || parts.length === 0) parts.push(`${secs}s`)

    return parts.join(' ')
  }

  return (
    <div className="bg-white border border-gray-200 rounded-lg p-4 hover:shadow-md transition-shadow">
      <div className="flex items-start justify-between">
        <div className="flex-1">
          <div className="flex items-center space-x-3 mb-2">
            {/* Event type badge */}
            <span className={clsx(
              'px-3 py-1 text-xs font-semibold rounded-full border',
              getEventBadgeColor(event.event_type)
            )}>
              {formatEventType(event.event_type)}
            </span>

            {/* Timestamp */}
            <span className="text-sm text-gray-600">
              {new Date(event.timestamp).toLocaleString()}
            </span>
          </div>

          {/* Duration (for downtime events) */}
          {event.duration && (
            <div className="flex items-center space-x-2 mb-2">
              <span className="text-sm font-medium text-gray-700">Duration:</span>
              <span className="text-sm text-gray-600">{formatDuration(event.duration)}</span>
            </div>
          )}

          {/* Details */}
          {event.details && (
            <div className="text-sm text-gray-700 mt-2">
              {event.details}
            </div>
          )}

          {/* Metadata */}
          {event.metadata && Object.keys(event.metadata).length > 0 && (
            <div className="mt-3 p-3 bg-gray-50 rounded-lg">
              <div className="text-xs font-medium text-gray-700 mb-2">Additional Information</div>
              <div className="space-y-1">
                {Object.entries(event.metadata).map(([key, value]) => (
                  <div key={key} className="flex items-center justify-between text-xs">
                    <span className="text-gray-600 capitalize">{key.replace('_', ' ')}:</span>
                    <span className="text-gray-900 font-medium">{value}</span>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>

        {/* Time ago indicator */}
        <div className="text-xs text-gray-500 ml-4">
          {getTimeAgo(new Date(event.timestamp))}
        </div>
      </div>
    </div>
  )
}

/**
 * Get human-readable time ago
 */
function getTimeAgo(date) {
  const now = new Date()
  const seconds = Math.floor((now - date) / 1000)

  if (seconds < 60) return 'Just now'
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`
  if (seconds < 604800) return `${Math.floor(seconds / 86400)}d ago`
  return date.toLocaleDateString()
}

export default UptimeHistory
