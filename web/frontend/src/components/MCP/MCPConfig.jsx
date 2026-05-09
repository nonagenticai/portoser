import React, { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Copy, Check, X } from 'lucide-react'
import { getMCPConfig } from '../../api/client'

function MCPConfig({ onClose }) {
  const [copied, setCopied] = useState(false)

  const { data: config, isLoading, error } = useQuery({
    queryKey: ['mcp-config'],
    queryFn: getMCPConfig,
  })

  const handleCopy = () => {
    const configJson = JSON.stringify(
      {
        'Portoser MCP Server': config,
      },
      null,
      2
    )
    navigator.clipboard.writeText(configJson)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  if (isLoading) {
    return (
      <div className="bg-white rounded-lg shadow-sm p-6 border border-gray-200">
        <div className="animate-pulse space-y-4">
          <div className="h-4 bg-gray-200 rounded w-1/4"></div>
          <div className="h-32 bg-gray-200 rounded"></div>
        </div>
      </div>
    )
  }

  if (error) {
    return (
      <div className="bg-red-50 border border-red-200 rounded-lg p-4 text-red-700">
        <p className="font-semibold">Error loading configuration</p>
        <p className="text-sm mt-1">{error.message}</p>
      </div>
    )
  }

  return (
    <div className="bg-white rounded-lg shadow-sm border border-gray-200">
      <div className="flex items-center justify-between p-6 border-b border-gray-200">
        <h2 className="text-lg font-semibold text-gray-900">MCP Client Configuration</h2>
        <button
          onClick={onClose}
          className="p-2 text-gray-400 hover:text-gray-600 rounded-lg hover:bg-gray-100 transition-colors"
        >
          <X className="w-5 h-5" />
        </button>
      </div>

      <div className="p-6 space-y-4">
        <p className="text-sm text-gray-600">
          Use this configuration to connect MCP clients (like Cursor IDE) to your Portoser MCP
          server. Copy and paste this into your MCP client configuration file.
        </p>

        <div className="relative">
          <pre className="bg-gray-900 text-gray-100 rounded-lg p-4 text-sm overflow-x-auto">
            {JSON.stringify(
              {
                'Portoser MCP Server': config,
              },
              null,
              2
            )}
          </pre>
          <button
            onClick={handleCopy}
            className="absolute top-4 right-4 flex items-center space-x-2 px-3 py-1.5 bg-gray-800 hover:bg-gray-700 text-white text-sm rounded transition-colors"
          >
            {copied ? (
              <>
                <Check className="w-4 h-4" />
                <span>Copied!</span>
              </>
            ) : (
              <>
                <Copy className="w-4 h-4" />
                <span>Copy</span>
              </>
            )}
          </button>
        </div>

        <div className="bg-blue-50 border border-blue-200 rounded-lg p-4">
          <h3 className="text-sm font-semibold text-blue-900 mb-2">Configuration Details</h3>
          <ul className="text-sm text-blue-800 space-y-1">
            <li>
              <span className="font-medium">URL:</span> {config?.url}
            </li>
            <li>
              <span className="font-medium">Post URL:</span> {config?.post_url}
            </li>
            <li>
              <span className="font-medium">Transport:</span> SSE (Server-Sent Events)
            </li>
            <li>
              <span className="font-medium">Message Format:</span> JSON-RPC 2.0
            </li>
          </ul>
        </div>

        <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4">
          <h3 className="text-sm font-semibold text-yellow-900 mb-2">
            For Cursor IDE Users
          </h3>
          <p className="text-sm text-yellow-800">
            Add this configuration to your <code className="px-1 bg-yellow-100 rounded">~/.cursor/mcp.json</code> file.
            You may need to restart Cursor after making changes.
          </p>
        </div>
      </div>
    </div>
  )
}

export default MCPConfig
