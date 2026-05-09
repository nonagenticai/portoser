import React, { useState } from 'react'
import { BarChart3, TrendingUp, Filter } from 'lucide-react'
import clsx from 'clsx'

function ProblemFrequencyChart({ data = [], timeRange = '7d', onProblemClick }) {
  const [selectedTimeRange, setSelectedTimeRange] = useState(timeRange)
  const [selectedService, setSelectedService] = useState('all')

  // Get unique services from data
  const services = ['all', ...new Set(data.map(item => item.service).filter(Boolean))]

  // Filter data based on selections
  const filteredData = data.filter(item => {
    if (selectedService !== 'all' && item.service !== selectedService) {
      return false
    }
    return true
  })

  // Find max count for scaling
  const maxCount = Math.max(...filteredData.map(item => item.count), 1)

  const getSeverityColor = (severity) => {
    switch (severity) {
      case 'critical':
        return 'bg-red-500 hover:bg-red-600'
      case 'high':
        return 'bg-orange-500 hover:bg-orange-600'
      case 'medium':
        return 'bg-yellow-500 hover:bg-yellow-600'
      case 'low':
        return 'bg-blue-500 hover:bg-blue-600'
      default:
        return 'bg-gray-500 hover:bg-gray-600'
    }
  }

  const getSeverityLightColor = (severity) => {
    switch (severity) {
      case 'critical':
        return 'bg-red-100 border-red-300'
      case 'high':
        return 'bg-orange-100 border-orange-300'
      case 'medium':
        return 'bg-yellow-100 border-yellow-300'
      case 'low':
        return 'bg-blue-100 border-blue-300'
      default:
        return 'bg-gray-100 border-gray-300'
    }
  }

  const getTimeRangeLabel = (range) => {
    switch (range) {
      case '24h':
        return 'Last 24 Hours'
      case '7d':
        return 'Last 7 Days'
      case '30d':
        return 'Last 30 Days'
      case '90d':
        return 'Last 90 Days'
      default:
        return range
    }
  }

  if (filteredData.length === 0) {
    return (
      <div className="bg-white rounded-lg border border-gray-200 p-6">
        <div className="flex items-center space-x-3 mb-6">
          <BarChart3 className="w-6 h-6 text-blue-600" />
          <h3 className="text-lg font-semibold text-gray-900">
            Problem Frequency
          </h3>
        </div>

        <div className="text-center py-12">
          <TrendingUp className="w-16 h-16 text-gray-400 mx-auto mb-4" />
          <h4 className="text-lg font-semibold text-gray-900 mb-2">
            No Data Available
          </h4>
          <p className="text-gray-600">
            No problems detected in the selected time range
          </p>
        </div>
      </div>
    )
  }

  return (
    <div className="bg-white rounded-lg border border-gray-200 p-6">
      {/* Header */}
      <div className="flex items-center justify-between mb-6">
        <div className="flex items-center space-x-3">
          <BarChart3 className="w-6 h-6 text-blue-600" />
          <h3 className="text-lg font-semibold text-gray-900">
            Problem Frequency
          </h3>
        </div>

        {/* Filters */}
        <div className="flex items-center space-x-3">
          {/* Time Range Selector */}
          <div className="flex items-center space-x-2">
            <Filter className="w-4 h-4 text-gray-600" />
            <select
              value={selectedTimeRange}
              onChange={(e) => setSelectedTimeRange(e.target.value)}
              className="border border-gray-300 rounded-lg px-3 py-1 text-sm"
            >
              <option value="24h">Last 24 Hours</option>
              <option value="7d">Last 7 Days</option>
              <option value="30d">Last 30 Days</option>
              <option value="90d">Last 90 Days</option>
            </select>
          </div>

          {/* Service Filter */}
          <select
            value={selectedService}
            onChange={(e) => setSelectedService(e.target.value)}
            className="border border-gray-300 rounded-lg px-3 py-1 text-sm"
          >
            {services.map(service => (
              <option key={service} value={service}>
                {service === 'all' ? 'All Services' : service}
              </option>
            ))}
          </select>
        </div>
      </div>

      {/* Chart */}
      <div className="space-y-3">
        {filteredData.map((item, idx) => {
          const barWidth = (item.count / maxCount) * 100

          return (
            <div
              key={idx}
              className="group cursor-pointer"
              onClick={() => onProblemClick && onProblemClick(item)}
            >
              {/* Problem Name and Count */}
              <div className="flex items-center justify-between mb-1">
                <div className="flex items-center space-x-2 flex-1 min-w-0">
                  <span className="text-sm font-medium text-gray-900 truncate">
                    {item.problem_type || item.name}
                  </span>
                  {item.service && (
                    <span className="text-xs text-gray-500 bg-gray-100 px-2 py-0.5 rounded">
                      {item.service}
                    </span>
                  )}
                </div>
                <span className="text-sm font-bold text-gray-900 ml-2">
                  {item.count}
                </span>
              </div>

              {/* Bar */}
              <div className="relative h-8 bg-gray-100 rounded-lg overflow-hidden">
                <div
                  className={clsx(
                    'h-full transition-all duration-300 relative',
                    getSeverityColor(item.severity)
                  )}
                  style={{ width: `${barWidth}%` }}
                >
                  {/* Hover tooltip */}
                  <div className="absolute inset-0 flex items-center justify-end pr-3">
                    <span className="text-xs text-white font-medium opacity-0 group-hover:opacity-100 transition-opacity">
                      {item.count} occurrences
                    </span>
                  </div>
                </div>
              </div>

              {/* Severity Badge and Trend */}
              <div className="flex items-center justify-between mt-1">
                <span className={clsx(
                  'text-xs px-2 py-0.5 rounded border font-medium',
                  getSeverityLightColor(item.severity)
                )}>
                  {item.severity.toUpperCase()}
                </span>

                {item.trend && (
                  <div className="flex items-center space-x-1 text-xs">
                    {item.trend === 'increasing' && (
                      <>
                        <TrendingUp className="w-3 h-3 text-red-600" />
                        <span className="text-red-600">+{item.trend_percentage}%</span>
                      </>
                    )}
                    {item.trend === 'decreasing' && (
                      <>
                        <TrendingUp className="w-3 h-3 text-green-600 transform rotate-180" />
                        <span className="text-green-600">-{item.trend_percentage}%</span>
                      </>
                    )}
                    {item.trend === 'stable' && (
                      <span className="text-gray-600">Stable</span>
                    )}
                  </div>
                )}
              </div>
            </div>
          )
        })}
      </div>

      {/* Legend */}
      <div className="mt-6 pt-4 border-t border-gray-200">
        <div className="flex items-center justify-center space-x-6 text-sm">
          <div className="flex items-center space-x-2">
            <div className="w-3 h-3 bg-red-500 rounded"></div>
            <span className="text-gray-700">Critical</span>
          </div>
          <div className="flex items-center space-x-2">
            <div className="w-3 h-3 bg-orange-500 rounded"></div>
            <span className="text-gray-700">High</span>
          </div>
          <div className="flex items-center space-x-2">
            <div className="w-3 h-3 bg-yellow-500 rounded"></div>
            <span className="text-gray-700">Medium</span>
          </div>
          <div className="flex items-center space-x-2">
            <div className="w-3 h-3 bg-blue-500 rounded"></div>
            <span className="text-gray-700">Low</span>
          </div>
        </div>
      </div>

      {/* Summary Stats */}
      <div className="mt-6 grid grid-cols-3 gap-4">
        <div className="text-center p-3 bg-gray-50 rounded-lg border border-gray-200">
          <div className="text-2xl font-bold text-gray-900">
            {filteredData.reduce((sum, item) => sum + item.count, 0)}
          </div>
          <div className="text-xs text-gray-600">Total Issues</div>
        </div>
        <div className="text-center p-3 bg-gray-50 rounded-lg border border-gray-200">
          <div className="text-2xl font-bold text-gray-900">
            {filteredData.length}
          </div>
          <div className="text-xs text-gray-600">Problem Types</div>
        </div>
        <div className="text-center p-3 bg-gray-50 rounded-lg border border-gray-200">
          <div className="text-2xl font-bold text-gray-900">
            {filteredData.filter(item => item.severity === 'critical' || item.severity === 'high').length}
          </div>
          <div className="text-xs text-gray-600">High Priority</div>
        </div>
      </div>
    </div>
  )
}

export default ProblemFrequencyChart
