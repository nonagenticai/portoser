import React, { useState, useRef, useEffect } from 'react'
import { Clock, ZoomIn, ZoomOut, Maximize2 } from 'lucide-react'
import { safeToFixed } from '../../utils/formatters'
import clsx from 'clsx'

/**
 * MetricsChart Component
 * Line chart showing resource usage over time using SVG
 * Supports multiple metrics, time range selection, and interactive tooltips
 */
function MetricsChart({ data, timeRange = '1h', onTimeRangeChange, height = 300 }) {
  const [hoveredPoint, setHoveredPoint] = useState(null)
  const [zoom, setZoom] = useState(1)
  const svgRef = useRef(null)

  const timeRanges = [
    { value: '1h', label: '1 Hour' },
    { value: '6h', label: '6 Hours' },
    { value: '24h', label: '24 Hours' },
    { value: '7d', label: '7 Days' },
    { value: '30d', label: '30 Days' }
  ]

  if (!data || !data.dataPoints || data.dataPoints.length === 0) {
    return (
      <div className="flex items-center justify-center h-64 bg-gray-50 rounded-lg border border-gray-200">
        <div className="text-center text-gray-500">
          <Clock className="w-8 h-8 mx-auto mb-2 opacity-50" />
          <p>No metrics data available</p>
        </div>
      </div>
    )
  }

  const metrics = data.metrics || ['cpu', 'memory']
  const dataPoints = data.dataPoints

  // Calculate statistics
  const stats = calculateStats(dataPoints, metrics)

  // Chart dimensions
  const padding = { top: 20, right: 20, bottom: 40, left: 50 }
  const width = 800
  const chartWidth = width - padding.left - padding.right
  const chartHeight = height - padding.top - padding.bottom

  // Scales
  const xScale = (index) => (index / (dataPoints.length - 1)) * chartWidth
  const yScale = (value) => chartHeight - (value / 100) * chartHeight

  // Generate path for a metric
  const generatePath = (metricKey) => {
    return dataPoints
      .map((point, index) => {
        const x = xScale(index)
        const y = yScale(point[metricKey] || 0)
        return `${index === 0 ? 'M' : 'L'} ${x},${y}`
      })
      .join(' ')
  }

  // Metric colors
  const metricColors = {
    cpu: { stroke: '#3b82f6', fill: 'rgba(59, 130, 246, 0.1)' },
    memory: { stroke: '#10b981', fill: 'rgba(16, 185, 129, 0.1)' },
    disk: { stroke: '#f59e0b', fill: 'rgba(245, 158, 11, 0.1)' }
  }

  // Format timestamp
  const formatTimestamp = (timestamp) => {
    const date = new Date(timestamp)
    if (timeRange === '1h' || timeRange === '6h') {
      return date.toLocaleTimeString()
    }
    return date.toLocaleDateString() + ' ' + date.toLocaleTimeString()
  }

  return (
    <div className="space-y-4">
      {/* Header with controls */}
      <div className="flex items-center justify-between flex-wrap gap-4">
        <div>
          <h3 className="text-lg font-semibold text-gray-900">Historical Metrics</h3>
          <p className="text-sm text-gray-500">{dataPoints.length} data points</p>
        </div>

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
              onClick={() => setZoom(Math.max(0.5, zoom - 0.25))}
              className="p-2 hover:bg-gray-100 transition-colors border-r border-gray-300"
              title="Zoom out"
            >
              <ZoomOut className="w-4 h-4" />
            </button>
            <button
              onClick={() => setZoom(1)}
              className="p-2 hover:bg-gray-100 transition-colors border-r border-gray-300"
              title="Reset zoom"
            >
              <Maximize2 className="w-4 h-4" />
            </button>
            <button
              onClick={() => setZoom(Math.min(3, zoom + 0.25))}
              className="p-2 hover:bg-gray-100 transition-colors"
              title="Zoom in"
            >
              <ZoomIn className="w-4 h-4" />
            </button>
          </div>
        </div>
      </div>

      {/* Legend with stats */}
      <div className="flex flex-wrap gap-4 p-4 bg-gray-50 rounded-lg">
        {metrics.map(metric => (
          <div key={metric} className="flex items-center space-x-3">
            <div
              className="w-3 h-3 rounded-full"
              style={{ backgroundColor: metricColors[metric]?.stroke || '#gray' }}
            />
            <div>
              <div className="flex items-center space-x-2">
                <span className="text-sm font-medium text-gray-700 capitalize">
                  {metric}
                </span>
              </div>
              <div className="flex space-x-3 text-xs text-gray-600">
                <span>Current: <strong>{safeToFixed(stats[metric]?.current, 1)}%</strong></span>
                <span>Avg: <strong>{safeToFixed(stats[metric]?.avg, 1)}%</strong></span>
                <span>Peak: <strong>{safeToFixed(stats[metric]?.peak, 1)}%</strong></span>
              </div>
            </div>
          </div>
        ))}
      </div>

      {/* Chart */}
      <div className="relative bg-white border border-gray-200 rounded-lg overflow-hidden">
        <svg
          ref={svgRef}
          width={width}
          height={height}
          className="w-full"
          style={{ transform: `scale(${zoom})`, transformOrigin: 'top left' }}
        >
          {/* Grid lines */}
          <g transform={`translate(${padding.left}, ${padding.top})`}>
            {/* Horizontal grid lines */}
            {[0, 25, 50, 75, 100].map(value => (
              <g key={value}>
                <line
                  x1={0}
                  y1={yScale(value)}
                  x2={chartWidth}
                  y2={yScale(value)}
                  stroke="#e5e7eb"
                  strokeWidth="1"
                />
                <text
                  x={-10}
                  y={yScale(value)}
                  textAnchor="end"
                  alignmentBaseline="middle"
                  className="text-xs fill-gray-500"
                >
                  {value}%
                </text>
              </g>
            ))}

            {/* Vertical grid lines (time markers) */}
            {dataPoints
              .filter((_, i) => i % Math.ceil(dataPoints.length / 8) === 0)
              .map((point, i) => {
                const index = dataPoints.indexOf(point)
                return (
                  <g key={i}>
                    <line
                      x1={xScale(index)}
                      y1={0}
                      x2={xScale(index)}
                      y2={chartHeight}
                      stroke="#e5e7eb"
                      strokeWidth="1"
                      strokeDasharray="2,2"
                    />
                    <text
                      x={xScale(index)}
                      y={chartHeight + 20}
                      textAnchor="middle"
                      className="text-xs fill-gray-500"
                    >
                      {new Date(point.timestamp).toLocaleTimeString([], {
                        hour: '2-digit',
                        minute: '2-digit'
                      })}
                    </text>
                  </g>
                )
              })}

            {/* Draw metric lines */}
            {metrics.map(metric => {
              const color = metricColors[metric] || { stroke: '#gray', fill: 'rgba(128,128,128,0.1)' }
              const path = generatePath(metric)

              return (
                <g key={metric}>
                  {/* Fill area */}
                  <path
                    d={`${path} L ${chartWidth},${chartHeight} L 0,${chartHeight} Z`}
                    fill={color.fill}
                  />
                  {/* Line */}
                  <path
                    d={path}
                    fill="none"
                    stroke={color.stroke}
                    strokeWidth="2"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </g>
              )
            })}

            {/* Interactive hover area */}
            {dataPoints.map((point, index) => (
              <circle
                key={index}
                cx={xScale(index)}
                cy={yScale(point[metrics[0]] || 0)}
                r="20"
                fill="transparent"
                onMouseEnter={() => setHoveredPoint({ point, index })}
                onMouseLeave={() => setHoveredPoint(null)}
                style={{ cursor: 'pointer' }}
              />
            ))}

            {/* Hovered point indicators */}
            {hoveredPoint && metrics.map(metric => (
              <circle
                key={metric}
                cx={xScale(hoveredPoint.index)}
                cy={yScale(hoveredPoint.point[metric] || 0)}
                r="4"
                fill={metricColors[metric]?.stroke || '#gray'}
                stroke="white"
                strokeWidth="2"
              />
            ))}
          </g>
        </svg>

        {/* Tooltip */}
        {hoveredPoint && (
          <div
            className="absolute bg-white border border-gray-200 rounded-lg shadow-lg p-3 pointer-events-none"
            style={{
              left: Math.min(xScale(hoveredPoint.index) + padding.left + 10, width - 200),
              top: padding.top + 10
            }}
          >
            <div className="text-xs font-medium text-gray-900 mb-2">
              {formatTimestamp(hoveredPoint.point.timestamp)}
            </div>
            {metrics.map(metric => (
              <div key={metric} className="flex items-center justify-between space-x-4 text-xs">
                <div className="flex items-center space-x-2">
                  <div
                    className="w-2 h-2 rounded-full"
                    style={{ backgroundColor: metricColors[metric]?.stroke }}
                  />
                  <span className="text-gray-600 capitalize">{metric}</span>
                </div>
                <span className="font-semibold text-gray-900">
                  {safeToFixed(hoveredPoint.point[metric] || 0, 1)}%
                </span>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

/**
 * Calculate statistics for metrics
 */
function calculateStats(dataPoints, metrics) {
  const stats = {}

  metrics.forEach(metric => {
    const values = dataPoints.map(p => p[metric] || 0)
    const current = values[values.length - 1] || 0
    const avg = values.reduce((a, b) => a + b, 0) / values.length
    const peak = Math.max(...values)

    stats[metric] = { current, avg, peak }
  })

  return stats
}

export default MetricsChart
