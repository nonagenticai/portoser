import React, { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Code, Trash2, Edit, Plus, Eye } from 'lucide-react'
import { getMCPTools, deleteMCPTool } from '../../api/client'

function MCPToolList({ onEditTool, onViewTool }) {
  const queryClient = useQueryClient()
  const [filter, setFilter] = useState('')

  const { data: toolsData, isLoading, error } = useQuery({
    queryKey: ['mcp-tools'],
    queryFn: getMCPTools,
    refetchInterval: 30000, // Refresh every 30 seconds
  })

  const deleteMutation = useMutation({
    mutationFn: (toolName) => deleteMCPTool(toolName),
    onSuccess: () => {
      queryClient.invalidateQueries(['mcp-tools'])
    },
  })

  const handleDelete = async (toolName) => {
    if (window.confirm(`Are you sure you want to delete tool "${toolName}"?`)) {
      try {
        await deleteMutation.mutateAsync(toolName)
      } catch (error) {
        alert(`Failed to delete tool: ${error.message}`)
      }
    }
  }

  if (isLoading) {
    return (
      <div className="flex items-center justify-center p-8">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600"></div>
      </div>
    )
  }

  if (error) {
    return (
      <div className="bg-red-50 border border-red-200 rounded-lg p-4 text-red-700">
        <p className="font-semibold">Error loading MCP tools</p>
        <p className="text-sm mt-1">{error.message}</p>
      </div>
    )
  }

  const tools = toolsData?.tools || []
  const filteredTools = tools.filter((tool) =>
    tool.name.toLowerCase().includes(filter.toLowerCase())
  )

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div className="flex-1 max-w-md">
          <input
            type="text"
            placeholder="Search tools..."
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
            className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
          />
        </div>
        <div className="text-sm text-gray-600">
          {filteredTools.length} {filteredTools.length === 1 ? 'tool' : 'tools'}
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        {filteredTools.map((tool) => (
          <div
            key={tool.name}
            className="bg-white border border-gray-200 rounded-lg p-4 hover:shadow-lg transition-shadow"
          >
            <div className="flex items-start justify-between mb-3">
              <div className="flex items-center space-x-2">
                <Code className="w-5 h-5 text-blue-600" />
                <h3 className="font-semibold text-gray-900">{tool.name}</h3>
              </div>
            </div>

            <p className="text-sm text-gray-600 mb-4 line-clamp-2">
              {tool.description || 'No description available'}
            </p>

            <div className="flex items-center justify-end space-x-2">
              <button
                onClick={() => onViewTool && onViewTool(tool)}
                className="p-2 text-gray-600 hover:text-blue-600 hover:bg-blue-50 rounded transition-colors"
                title="View details"
              >
                <Eye className="w-4 h-4" />
              </button>
              <button
                onClick={() => onEditTool && onEditTool(tool)}
                className="p-2 text-gray-600 hover:text-yellow-600 hover:bg-yellow-50 rounded transition-colors"
                title="Edit tool"
              >
                <Edit className="w-4 h-4" />
              </button>
              <button
                onClick={() => handleDelete(tool.name)}
                disabled={deleteMutation.isLoading}
                className="p-2 text-gray-600 hover:text-red-600 hover:bg-red-50 rounded transition-colors disabled:opacity-50"
                title="Delete tool"
              >
                <Trash2 className="w-4 h-4" />
              </button>
            </div>
          </div>
        ))}
      </div>

      {filteredTools.length === 0 && (
        <div className="text-center py-12 text-gray-500">
          <Code className="w-12 h-12 mx-auto mb-4 text-gray-400" />
          <p className="text-lg font-medium">No tools found</p>
          <p className="text-sm">
            {filter ? 'Try adjusting your search filter' : 'Create your first MCP tool to get started'}
          </p>
        </div>
      )}
    </div>
  )
}

export default MCPToolList
