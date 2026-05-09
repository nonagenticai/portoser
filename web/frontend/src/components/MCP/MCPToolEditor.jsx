import React, { useState, useEffect } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Save, X, Code } from 'lucide-react'
import { createMCPTool, updateMCPTool } from '../../api/client'

function MCPToolEditor({ tool, onClose, onSuccess }) {
  const queryClient = useQueryClient()
  const [formData, setFormData] = useState({
    name: '',
    description: '',
    code: '',
    replace_existing: false,
  })

  useEffect(() => {
    if (tool) {
      setFormData({
        name: tool.name || '',
        description: tool.description || '',
        code: tool.code || '',
        replace_existing: true,
      })
    }
  }, [tool])

  const createMutation = useMutation({
    mutationFn: (data) => createMCPTool(data),
    onSuccess: () => {
      queryClient.invalidateQueries(['mcp-tools'])
      onSuccess && onSuccess()
    },
  })

  const updateMutation = useMutation({
    mutationFn: ({ name, data }) => updateMCPTool(name, data),
    onSuccess: () => {
      queryClient.invalidateQueries(['mcp-tools'])
      onSuccess && onSuccess()
    },
  })

  const handleSubmit = async (e) => {
    e.preventDefault()

    try {
      if (tool) {
        // Update existing tool
        await updateMutation.mutateAsync({
          name: tool.name,
          data: {
            description: formData.description,
            code: formData.code,
          },
        })
      } else {
        // Create new tool
        await createMutation.mutateAsync(formData)
      }
    } catch (error) {
      alert(`Failed to ${tool ? 'update' : 'create'} tool: ${error.message}`)
    }
  }

  const isLoading = createMutation.isLoading || updateMutation.isLoading

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 p-4">
      <div className="bg-white rounded-lg shadow-xl max-w-4xl w-full max-h-[90vh] overflow-hidden">
        <div className="flex items-center justify-between p-6 border-b border-gray-200">
          <div className="flex items-center space-x-2">
            <Code className="w-6 h-6 text-blue-600" />
            <h2 className="text-xl font-bold text-gray-900">
              {tool ? `Edit Tool: ${tool.name}` : 'Create New MCP Tool'}
            </h2>
          </div>
          <button
            onClick={onClose}
            className="p-2 text-gray-400 hover:text-gray-600 rounded-lg hover:bg-gray-100 transition-colors"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        <form onSubmit={handleSubmit} className="overflow-y-auto max-h-[calc(90vh-140px)]">
          <div className="p-6 space-y-6">
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                Tool Name <span className="text-red-500">*</span>
              </label>
              <input
                type="text"
                value={formData.name}
                onChange={(e) => setFormData({ ...formData, name: e.target.value })}
                disabled={!!tool} // Disable name editing for existing tools
                required
                className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent disabled:bg-gray-100 disabled:cursor-not-allowed"
                placeholder="my_tool"
              />
              {tool && (
                <p className="mt-1 text-sm text-gray-500">
                  Tool name cannot be changed after creation
                </p>
              )}
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                Description <span className="text-red-500">*</span>
              </label>
              <textarea
                value={formData.description}
                onChange={(e) => setFormData({ ...formData, description: e.target.value })}
                required
                rows={3}
                className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                placeholder="Describe what this tool does..."
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                Python Code <span className="text-red-500">*</span>
              </label>
              <textarea
                value={formData.code}
                onChange={(e) => setFormData({ ...formData, code: e.target.value })}
                required
                rows={15}
                className="w-full px-4 py-2 font-mono text-sm border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                placeholder="def my_tool(param1: str) -> str:&#10;    &quot;&quot;&quot;Tool documentation&quot;&quot;&quot;&#10;    return f'Result: {param1}'"
              />
              <p className="mt-1 text-sm text-gray-500">
                Define your tool function here. It will be registered with MCP automatically.
              </p>
            </div>

            {!tool && (
              <div className="flex items-center space-x-2">
                <input
                  type="checkbox"
                  id="replace_existing"
                  checked={formData.replace_existing}
                  onChange={(e) =>
                    setFormData({ ...formData, replace_existing: e.target.checked })
                  }
                  className="w-4 h-4 text-blue-600 border-gray-300 rounded focus:ring-blue-500"
                />
                <label htmlFor="replace_existing" className="text-sm text-gray-700">
                  Replace existing tool if it exists
                </label>
              </div>
            )}
          </div>

          <div className="flex items-center justify-end space-x-3 p-6 border-t border-gray-200 bg-gray-50">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 text-gray-700 bg-white border border-gray-300 rounded-lg hover:bg-gray-50 transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={isLoading}
              className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <Save className="w-4 h-4" />
              <span>{isLoading ? 'Saving...' : tool ? 'Update Tool' : 'Create Tool'}</span>
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}

export default MCPToolEditor
