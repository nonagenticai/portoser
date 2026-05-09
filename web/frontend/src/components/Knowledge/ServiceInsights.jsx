import React from 'react'
import { useQuery } from '@tanstack/react-query'
import { Activity, AlertCircle, BarChart3, Clock, Package, Zap } from 'lucide-react'
import { getServiceInsights } from '../../api/client'

// Renders the new ServiceInsights shape from the on-disk reader. Anything
// the reader can't actually source (deployment timeline, solutions history,
// reliability score) is intentionally absent rather than faked.
function ServiceInsights({ serviceName }) {
  const { data: insights, isLoading } = useQuery({
    queryKey: ['service-insights', serviceName],
    queryFn: () => getServiceInsights(serviceName),
    enabled: !!serviceName,
  })

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Activity className="w-12 h-12 text-blue-600 animate-spin" />
      </div>
    )
  }

  if (!insights) {
    return (
      <div className="text-center py-12">
        <AlertCircle className="w-16 h-16 text-gray-400 mx-auto mb-4" />
        <h3 className="text-lg font-semibold text-gray-900 mb-2">No Data Available</h3>
        <p className="text-gray-600">Insights for {serviceName} are not available yet</p>
      </div>
    )
  }

  const noData = insights.deployment_count === 0 && insights.solutions_applied === 0

  return (
    <div className="space-y-6">
      <div className="flex items-center space-x-3">
        <div className="p-2 bg-purple-100 rounded-lg">
          <Package className="w-6 h-6 text-purple-600" />
        </div>
        <div>
          <h2 className="text-xl font-bold text-gray-900">Service Insights</h2>
          <p className="text-sm text-gray-600">{insights.service}</p>
        </div>
        {noData && (
          <span className="ml-auto px-3 py-1 rounded bg-gray-100 text-gray-700 border border-gray-300 text-xs font-medium">
            no data
          </span>
        )}
      </div>

      <div className="bg-white rounded-lg border border-gray-200 p-6">
        <h3 className="text-lg font-semibold text-gray-900 mb-4 flex items-center space-x-2">
          <BarChart3 className="w-5 h-5 text-blue-600" />
          <span>Deployment Activity</span>
        </h3>
        <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
          <div className="text-center p-4 bg-blue-50 rounded-lg border border-blue-200">
            <div className="text-3xl font-bold text-blue-700 mb-1">
              {insights.deployment_count ?? 0}
            </div>
            <div className="text-sm text-gray-600">Deployments tracked</div>
          </div>
          <div className="text-center p-4 bg-green-50 rounded-lg border border-green-200">
            <div className="text-3xl font-bold text-green-700 mb-1">
              {insights.solutions_applied ?? 0}
            </div>
            <div className="text-sm text-gray-600">Solutions applied</div>
          </div>
          <div className="text-center p-4 bg-purple-50 rounded-lg border border-purple-200">
            <div className="text-3xl font-bold text-purple-700 mb-1">
              {insights.avg_duration_seconds == null
                ? '—'
                : `${Math.round(insights.avg_duration_seconds)}s`}
            </div>
            <div className="text-sm text-gray-600 flex items-center justify-center space-x-1">
              <Clock className="w-3 h-3" />
              <span>Avg duration</span>
            </div>
          </div>
        </div>
      </div>

      <div className="bg-white rounded-lg border border-gray-200 p-6">
        <h3 className="text-lg font-semibold text-gray-900 mb-4 flex items-center space-x-2">
          <AlertCircle className="w-5 h-5 text-orange-600" />
          <span>Common Problems</span>
        </h3>
        {(insights.common_problems ?? []).length === 0 ? (
          <p className="text-sm text-gray-600">No problems recorded for this service.</p>
        ) : (
          <div className="space-y-3">
            {insights.common_problems.map((problem) => (
              <div
                key={problem.problem}
                className="flex items-center justify-between p-4 bg-gray-50 rounded-lg border border-gray-200"
              >
                <div className="flex items-center space-x-2">
                  <Zap className="w-4 h-4 text-yellow-600" />
                  <h4 className="font-medium text-gray-900">{problem.problem}</h4>
                </div>
                <div className="text-center">
                  <div className="text-2xl font-bold text-gray-900">{problem.count}</div>
                  <div className="text-xs text-gray-600">occurrences</div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

export default ServiceInsights
