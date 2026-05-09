import React, { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import {
  AlertCircle,
  BarChart3,
  BookOpen,
  Brain,
  Package,
  Search,
  Wrench,
  Zap,
} from 'lucide-react'
import clsx from 'clsx'
import PlaybookViewer from '../components/Knowledge/PlaybookViewer'
import ServiceInsights from '../components/Knowledge/ServiceInsights'
import { fetchServices, getKnowledgeStats } from '../api/client'

// Top-level KB page. v1 stats tab is intentionally minimal — we only
// surface what the on-disk reader can actually source. Apply-Solution,
// Recent Learnings, and "best performing solution" tiles were dropped
// because no backend code emits the data behind them.
function KnowledgeBase() {
  const [activeTab, setActiveTab] = useState('playbooks')
  const [selectedService, setSelectedService] = useState(null)
  const [searchQuery, setSearchQuery] = useState('')

  const { data: services = [] } = useQuery({
    queryKey: ['services'],
    queryFn: fetchServices,
  })

  const { data: statistics = {} } = useQuery({
    queryKey: ['knowledge-stats'],
    queryFn: getKnowledgeStats,
  })

  const tabs = [
    { id: 'playbooks', label: 'Playbooks', icon: BookOpen },
    { id: 'insights', label: 'Service Insights', icon: Package },
    { id: 'statistics', label: 'Statistics', icon: BarChart3 },
  ]

  const filteredServices = services.filter((service) =>
    service.name.toLowerCase().includes(searchQuery.toLowerCase())
  )

  // Show all services so the insights tab doesn't just look broken when
  // the KB is fresh. Sort by recorded activity so the ones with data
  // float up; "no data" rows get a soft badge.
  const servicesWithData = services.map((s) => ({
    ...s,
    _deploymentCount: 0, // updated lazily inside the row if we ever fetch
  }))

  const commonProblems = Array.isArray(statistics.most_common_problems)
    ? statistics.most_common_problems
    : []
  const playbooksByCategory = statistics.playbooks_by_category || {}

  return (
    <div className="min-h-screen bg-gray-50">
      <div className="bg-white border-b border-gray-200">
        <div className="container mx-auto px-4 py-6">
          <div className="flex items-center space-x-3">
            <div className="p-2 bg-gradient-to-br from-purple-500 to-pink-600 rounded-lg">
              <Brain className="w-8 h-8 text-white" />
            </div>
            <div>
              <h1 className="text-2xl font-bold text-gray-900">Knowledge Base</h1>
              <p className="text-sm text-gray-600">
                Read-only view of <code>~/.portoser/knowledge</code> — playbooks, problem
                history, and applied solutions written by the CLI.
              </p>
            </div>
          </div>
        </div>
      </div>

      <div className="bg-white border-b border-gray-200">
        <div className="container mx-auto px-4">
          <div className="flex space-x-1">
            {tabs.map((tab) => (
              <button
                key={tab.id}
                onClick={() => setActiveTab(tab.id)}
                className={clsx(
                  'px-6 py-4 text-sm font-medium transition-colors flex items-center space-x-2',
                  {
                    'text-blue-600 border-b-2 border-blue-600': activeTab === tab.id,
                    'text-gray-600 hover:text-gray-900': activeTab !== tab.id,
                  }
                )}
              >
                <tab.icon className="w-5 h-5" />
                <span>{tab.label}</span>
              </button>
            ))}
          </div>
        </div>
      </div>

      <div className="container mx-auto px-4 py-8">
        {activeTab === 'playbooks' && (
          <div
            className="bg-white rounded-lg border border-gray-200 overflow-hidden"
            style={{ height: 'calc(100vh - 280px)' }}
          >
            <PlaybookViewer />
          </div>
        )}

        {activeTab === 'insights' && (
          <div>
            {!selectedService ? (
              <div>
                <div className="mb-6">
                  <div className="relative">
                    <Search className="absolute left-4 top-1/2 transform -translate-y-1/2 w-5 h-5 text-gray-400" />
                    <input
                      type="text"
                      value={searchQuery}
                      onChange={(e) => setSearchQuery(e.target.value)}
                      placeholder="Search services..."
                      className="w-full pl-12 pr-4 py-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                    />
                  </div>
                </div>

                <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                  {filteredServices.map((service) => (
                    <div
                      key={service.name}
                      onClick={() => setSelectedService(service)}
                      className="bg-white border border-gray-200 rounded-lg p-6 cursor-pointer hover:border-blue-500 hover:shadow-lg transition-all"
                    >
                      <div className="flex items-center space-x-3 mb-4">
                        <div className="p-2 bg-purple-100 rounded-lg">
                          <Package className="w-6 h-6 text-purple-600" />
                        </div>
                        <div className="flex-1 min-w-0">
                          <h3 className="font-semibold text-gray-900 truncate">
                            {service.name}
                          </h3>
                          <p className="text-sm text-gray-600 truncate">
                            {service.machine_name || 'Unknown machine'}
                          </p>
                        </div>
                      </div>
                      <button className="mt-2 w-full px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-lg hover:bg-blue-700 transition-colors">
                        View Insights
                      </button>
                    </div>
                  ))}
                </div>

                {filteredServices.length === 0 && (
                  <div className="text-center py-12">
                    <Package className="w-16 h-16 text-gray-400 mx-auto mb-4" />
                    <h3 className="text-lg font-semibold text-gray-900 mb-2">
                      No Services Found
                    </h3>
                    <p className="text-gray-600">
                      {searchQuery ? 'Try a different search query' : 'No services available'}
                    </p>
                  </div>
                )}
              </div>
            ) : (
              <div>
                <button
                  onClick={() => setSelectedService(null)}
                  className="mb-4 text-blue-600 hover:text-blue-700 font-medium"
                >
                  ← Back to services
                </button>
                <ServiceInsights serviceName={selectedService.name} />
              </div>
            )}
          </div>
        )}

        {activeTab === 'statistics' && (
          <div className="space-y-6">
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
              <StatCard
                icon={BookOpen}
                color="blue"
                value={statistics.total_playbooks ?? 0}
                label="Total Playbooks"
              />
              <StatCard
                icon={Wrench}
                color="purple"
                value={statistics.total_deployments ?? 0}
                label="Deployments tracked"
              />
              <StatCard
                icon={AlertCircle}
                color="orange"
                value={statistics.total_problems ?? 0}
                label="Distinct problems"
              />
              <StatCard
                icon={Zap}
                color="green"
                value={statistics.total_solutions ?? 0}
                label="Solutions applied"
              />
            </div>

            <div className="bg-white rounded-lg border border-gray-200 p-6">
              <h3 className="text-lg font-semibold text-gray-900 mb-4 flex items-center space-x-2">
                <AlertCircle className="w-5 h-5 text-orange-600" />
                <span>Most common problems</span>
              </h3>
              {commonProblems.length === 0 ? (
                <p className="text-sm text-gray-600">
                  No problem history recorded yet. The CLI populates this as diagnostics run.
                </p>
              ) : (
                <ul className="divide-y divide-gray-200">
                  {commonProblems.map((p) => (
                    <li
                      key={p.problem}
                      className="flex items-center justify-between py-3"
                    >
                      <span className="font-medium text-gray-900">{p.problem}</span>
                      <span className="text-gray-700">{p.count} occurrences</span>
                    </li>
                  ))}
                </ul>
              )}
            </div>

            <div className="bg-white rounded-lg border border-gray-200 p-6">
              <h3 className="text-lg font-semibold text-gray-900 mb-4 flex items-center space-x-2">
                <BookOpen className="w-5 h-5 text-blue-600" />
                <span>Playbooks by category</span>
              </h3>
              {Object.keys(playbooksByCategory).length === 0 ? (
                <p className="text-sm text-gray-600">No playbooks yet.</p>
              ) : (
                <ul className="divide-y divide-gray-200">
                  {Object.entries(playbooksByCategory).map(([category, count]) => (
                    <li key={category} className="flex items-center justify-between py-3">
                      <span className="font-medium text-gray-900">{category}</span>
                      <span className="text-gray-700">{count}</span>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

function StatCard({ icon: Icon, color, value, label }) {
  // Tailwind purges classes it can't see at build time, so the colour map
  // has to be a literal lookup rather than a template string.
  const palette = {
    blue: 'bg-blue-100 text-blue-600',
    purple: 'bg-purple-100 text-purple-600',
    orange: 'bg-orange-100 text-orange-600',
    green: 'bg-green-100 text-green-600',
  }
  return (
    <div className="bg-white rounded-lg border border-gray-200 p-6">
      <div className="flex items-center space-x-3 mb-3">
        <div className={clsx('p-2 rounded-lg', palette[color] || palette.blue)}>
          <Icon className="w-6 h-6" />
        </div>
        <div className="text-3xl font-bold text-gray-900">{value}</div>
      </div>
      <div className="text-sm text-gray-600">{label}</div>
    </div>
  )
}

export default KnowledgeBase
