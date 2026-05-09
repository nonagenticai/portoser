import React, { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { BookOpen, Search, Target, Activity, Clock } from 'lucide-react'
import clsx from 'clsx'
import { getPlaybooks } from '../../api/client'

// Read-only viewer over the on-disk KB. Shapes match
// web/backend/models/knowledge.py:Playbook — `name` is the id, stats live
// under `playbook.stats`. Apply-Solution / Applicable badges were dropped:
// no executor exists, so the v1 surface is read-only documentation.
function PlaybookViewer() {
  const [searchQuery, setSearchQuery] = useState('')
  const [selectedPlaybook, setSelectedPlaybook] = useState(null)

  const { data: playbooks = [], isLoading } = useQuery({
    queryKey: ['playbooks'],
    queryFn: () => getPlaybooks(),
  })

  const filteredPlaybooks = playbooks.filter((playbook) => {
    if (!searchQuery) return true
    const q = searchQuery.toLowerCase()
    return (
      playbook.title?.toLowerCase().includes(q) ||
      playbook.description?.toLowerCase().includes(q) ||
      playbook.name?.toLowerCase().includes(q) ||
      (playbook.tags || []).some((t) => t.toLowerCase().includes(q))
    )
  })

  const successRateColor = (rate) => {
    const pct = (rate ?? 0) * 100
    if (pct >= 90) return 'text-green-600'
    if (pct >= 70) return 'text-yellow-600'
    return 'text-orange-600'
  }

  const formatPct = (rate) => `${Math.round((rate ?? 0) * 100)}%`

  return (
    <div className="flex h-full">
      <div className="w-96 border-r border-gray-200 bg-white flex flex-col">
        <div className="p-4 border-b border-gray-200">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 w-5 h-5 text-gray-400" />
            <input
              type="text"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              placeholder="Search playbooks..."
              className="w-full pl-10 pr-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
            />
          </div>
        </div>

        <div className="flex-1 overflow-y-auto">
          {isLoading ? (
            <div className="p-8 text-center">
              <Activity className="w-12 h-12 text-blue-600 mx-auto mb-3 animate-spin" />
              <p className="text-gray-600">Loading playbooks...</p>
            </div>
          ) : filteredPlaybooks.length === 0 ? (
            <div className="p-8 text-center">
              <BookOpen className="w-12 h-12 text-gray-400 mx-auto mb-3" />
              <p className="text-gray-600">No playbooks found</p>
              <p className="text-xs text-gray-500 mt-2">
                Playbooks live under <code>~/.portoser/knowledge/playbooks/</code> and are populated by the CLI.
              </p>
            </div>
          ) : (
            <div className="divide-y divide-gray-200">
              {filteredPlaybooks.map((playbook) => (
                <div
                  key={playbook.name}
                  onClick={() => setSelectedPlaybook(playbook)}
                  className={clsx('p-4 cursor-pointer transition-colors hover:bg-gray-50', {
                    'bg-blue-50 border-l-4 border-blue-600':
                      selectedPlaybook?.name === playbook.name,
                  })}
                >
                  <h3 className="font-semibold text-gray-900 mb-1">{playbook.title}</h3>
                  {playbook.description && (
                    <p className="text-sm text-gray-600 mb-3 line-clamp-2">
                      {playbook.description}
                    </p>
                  )}

                  <div className="flex items-center justify-between text-xs">
                    <span className="px-2 py-1 rounded border bg-gray-100 text-gray-800 border-gray-300 font-medium">
                      {playbook.category || 'general'}
                    </span>
                    <div className="flex items-center space-x-3">
                      <div className="flex items-center space-x-1">
                        <Target
                          className={clsx('w-3 h-3', successRateColor(playbook.stats?.success_rate))}
                        />
                        <span className={successRateColor(playbook.stats?.success_rate)}>
                          {formatPct(playbook.stats?.success_rate)}
                        </span>
                      </div>
                      <div className="flex items-center space-x-1 text-gray-600">
                        <Clock className="w-3 h-3" />
                        <span>{playbook.stats?.occurrences ?? 0}</span>
                      </div>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      <div className="flex-1 bg-gray-50 overflow-y-auto">
        {selectedPlaybook ? (
          <div className="max-w-4xl mx-auto p-8">
            <div className="bg-white rounded-lg border border-gray-200 p-6 mb-6">
              <h1 className="text-2xl font-bold text-gray-900 mb-2">
                {selectedPlaybook.title}
              </h1>
              {selectedPlaybook.description && (
                <p className="text-gray-600 mb-4">{selectedPlaybook.description}</p>
              )}

              <div className="flex flex-wrap items-center gap-2 mb-4">
                <span className="px-3 py-1 rounded-lg bg-gray-100 text-gray-800 border border-gray-300 font-medium text-sm">
                  {selectedPlaybook.category || 'general'}
                </span>
                {(selectedPlaybook.tags || []).map((tag) => (
                  <span
                    key={tag}
                    className="px-2 py-1 rounded bg-blue-50 text-blue-800 border border-blue-200 text-xs"
                  >
                    {tag}
                  </span>
                ))}
              </div>

              <div className="grid grid-cols-3 gap-4 pt-4 border-t border-gray-200">
                <div className="text-center">
                  <div
                    className={clsx(
                      'text-2xl font-bold mb-1',
                      successRateColor(selectedPlaybook.stats?.success_rate)
                    )}
                  >
                    {formatPct(selectedPlaybook.stats?.success_rate)}
                  </div>
                  <div className="text-xs text-gray-600 flex items-center justify-center space-x-1">
                    <Target className="w-3 h-3" />
                    <span>Success Rate</span>
                  </div>
                </div>
                <div className="text-center">
                  <div className="text-2xl font-bold text-gray-900 mb-1">
                    {selectedPlaybook.stats?.occurrences ?? 0}
                  </div>
                  <div className="text-xs text-gray-600 flex items-center justify-center space-x-1">
                    <Clock className="w-3 h-3" />
                    <span>Occurrences</span>
                  </div>
                </div>
                <div className="text-center">
                  <div className="text-sm font-medium text-gray-900 mb-1">
                    {selectedPlaybook.stats?.last_used
                      ? new Date(selectedPlaybook.stats.last_used).toLocaleDateString()
                      : '—'}
                  </div>
                  <div className="text-xs text-gray-600 flex items-center justify-center space-x-1">
                    <Clock className="w-3 h-3" />
                    <span>Last Used</span>
                  </div>
                </div>
              </div>
            </div>

            {selectedPlaybook.related_problems?.length > 0 && (
              <div className="bg-white rounded-lg border border-gray-200 p-6 mb-6">
                <h2 className="text-lg font-semibold text-gray-900 mb-3">
                  Related Problems
                </h2>
                <div className="flex flex-wrap gap-2">
                  {selectedPlaybook.related_problems.map((problem) => (
                    <span
                      key={problem}
                      className="px-3 py-1 bg-yellow-50 text-yellow-800 border border-yellow-300 rounded-lg text-sm"
                    >
                      {problem}
                    </span>
                  ))}
                </div>
              </div>
            )}

            <div className="bg-white rounded-lg border border-gray-200 p-6">
              {/* react-markdown isn't a dep yet; raw markdown in <pre> is the
                  v1 fallback the plan accepts. Swap for ReactMarkdown when
                  the dep is added. */}
              <pre className="whitespace-pre-wrap text-sm text-gray-800 font-mono">
                {selectedPlaybook.markdown_content || ''}
              </pre>
            </div>
          </div>
        ) : (
          <div className="flex items-center justify-center h-full">
            <div className="text-center">
              <BookOpen className="w-16 h-16 text-gray-400 mx-auto mb-4" />
              <h3 className="text-lg font-semibold text-gray-900 mb-2">
                Select a Playbook
              </h3>
              <p className="text-gray-600">
                Choose a playbook from the list to view details
              </p>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

export default PlaybookViewer
