import { useState, useEffect, useCallback } from 'react';
import { useQuery } from '@tanstack/react-query';
import ReactFlow, {
  Background,
  Controls,
  MiniMap,
  useNodesState,
  useEdgesState,
  MarkerType,
  Panel,
  Handle,
  Position,
} from 'reactflow';
import 'reactflow/dist/style.css';
import api from '../api/client';
import { Network, AlertCircle, CheckCircle, XCircle, Loader, Search } from 'lucide-react';
import DependencyPanel from '../components/Dependencies/DependencyPanel';

// Node colors based on health status
const healthColors = {
  healthy: '#10b981',
  degraded: '#f59e0b',
  unhealthy: '#ef4444',
  stopped: '#6b7280',
  unknown: '#9ca3af',
};

// Custom node component.
// Needs both target (incoming) and source (outgoing) handles so ReactFlow
// has anchors for the edges. Without these, edges silently render no path.
const CustomNode = ({ data }) => {
  const bgColor = healthColors[data.health] || healthColors.unknown;

  return (
    <div
      className="px-4 py-2 shadow-md rounded-lg border-2 min-w-[150px]"
      style={{
        borderColor: bgColor,
        backgroundColor: 'white',
      }}
    >
      <Handle type="target" position={Position.Left} style={{ background: bgColor }} />
      <div className="flex items-center gap-2">
        <div className="w-3 h-3 rounded-full" style={{ backgroundColor: bgColor }} />
        <div className="font-semibold text-sm">{data.label}</div>
      </div>
      <div className="text-xs text-gray-500 mt-1">{data.type}</div>
      <div className="text-xs text-gray-400">{data.host}</div>
      <Handle type="source" position={Position.Right} style={{ background: bgColor }} />
    </div>
  );
};

const nodeTypes = {
  custom: CustomNode,
};

export default function DependenciesGraph() {
  const [selectedNode, setSelectedNode] = useState(null);
  const [nodes, setNodes, onNodesChange] = useNodesState([]);
  const [edges, setEdges, onEdgesChange] = useEdgesState([]);
  const [searchTerm, setSearchTerm] = useState('');
  const [layoutType, setLayoutType] = useState('hierarchical');

  // Fetch dependency graph
  const { data: graphData, isLoading, error, refetch } = useQuery({
    queryKey: ['dependency-graph'],
    queryFn: async () => {
      const response = await api.get(`/dependencies/graph`);
      return response.data;
    },
    refetchInterval: 30000, // Refresh every 30 seconds
  });

  // Calculate layout positions
  const calculateLayout = useCallback((nodes, edges, type) => {
    if (type === 'hierarchical') {
      // Simple hierarchical layout. ReactFlow edges use {source,target}
      // (not the {from,to} shape returned by the dependency-graph API),
      // so read both fields to stay tolerant.
      const edgeSource = (e) => e.source ?? e.from;
      const edgeTarget = (e) => e.target ?? e.to;

      const levels = new Map();
      const visited = new Set();

      const assignLevel = (nodeId, level) => {
        if (visited.has(nodeId)) return;
        visited.add(nodeId);

        const currentLevel = levels.get(nodeId) || 0;
        levels.set(nodeId, Math.max(currentLevel, level));

        // Walk outgoing edges so dependents land below the things they need.
        const deps = edges.filter(e => edgeSource(e) === nodeId);
        deps.forEach(dep => assignLevel(edgeTarget(dep), level + 1));
      };

      // Start from nodes with no incoming edges (true roots).
      const rootNodes = nodes.filter(
        node => !edges.some(edge => edgeTarget(edge) === node.id)
      );

      rootNodes.forEach(node => assignLevel(node.id, 0));

      // Assign positions
      const levelGroups = new Map();
      levels.forEach((level, nodeId) => {
        if (!levelGroups.has(level)) {
          levelGroups.set(level, []);
        }
        levelGroups.get(level).push(nodeId);
      });

      return nodes.map(node => {
        const level = levels.get(node.id) || 0;
        const nodesInLevel = levelGroups.get(level) || [];
        const indexInLevel = nodesInLevel.indexOf(node.id);

        return {
          ...node,
          position: {
            x: level * 250,
            y: indexInLevel * 100,
          },
        };
      });
    } else if (type === 'circular') {
      // Circular layout
      const radius = Math.max(200, nodes.length * 30);
      const angleStep = (2 * Math.PI) / nodes.length;

      return nodes.map((node, index) => ({
        ...node,
        position: {
          x: 400 + radius * Math.cos(index * angleStep),
          y: 300 + radius * Math.sin(index * angleStep),
        },
      }));
    } else {
      // Grid layout
      const cols = Math.ceil(Math.sqrt(nodes.length));
      return nodes.map((node, index) => ({
        ...node,
        position: {
          x: (index % cols) * 250,
          y: Math.floor(index / cols) * 100,
        },
      }));
    }
  }, []);

  // Update graph when data changes
  useEffect(() => {
    if (!graphData) return;

    const graphNodes = graphData.nodes.map(node => ({
      id: node.id,
      type: 'custom',
      data: {
        label: node.label,
        type: node.type,
        host: node.host,
        hostname: node.hostname,
        health: node.health,
      },
      position: { x: 0, y: 0 },
    }));

    const graphEdges = graphData.edges.map((edge, index) => ({
      id: `e-${edge.from}-${edge.to}-${index}`,
      source: edge.from,
      target: edge.to,
      type: 'smoothstep',
      animated: edge.type === 'required',
      markerEnd: {
        type: MarkerType.ArrowClosed,
        width: 20,
        height: 20,
      },
      label: edge.type === 'optional' ? 'optional' : '',
      style: { stroke: edge.type === 'required' ? '#6366f1' : '#d1d5db' },
    }));

    const positionedNodes = calculateLayout(graphNodes, graphEdges, layoutType);
    setNodes(positionedNodes);
    setEdges(graphEdges);
  }, [graphData, layoutType, setNodes, setEdges, calculateLayout]);

  // Handle node click
  const onNodeClick = useCallback((event, node) => {
    setSelectedNode(node.id);
  }, []);

  // Highlight connected nodes
  const highlightedNodes = useCallback(() => {
    if (!selectedNode) return new Set();

    const connected = new Set([selectedNode]);
    edges.forEach(edge => {
      if (edge.source === selectedNode) connected.add(edge.target);
      if (edge.target === selectedNode) connected.add(edge.source);
    });

    return connected;
  }, [selectedNode, edges]);

  const highlighted = highlightedNodes();

  // Filter nodes by search term
  const filteredNodes = nodes.map(node => ({
    ...node,
    style: {
      ...node.style,
      opacity: searchTerm && !node.data.label.toLowerCase().includes(searchTerm.toLowerCase()) ? 0.3 : 1,
    },
  }));

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-full">
        <Loader className="w-8 h-8 animate-spin text-indigo-600" />
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex flex-col items-center justify-center h-full gap-4">
        <AlertCircle className="w-12 h-12 text-red-500" />
        <p className="text-gray-600">Failed to load dependency graph</p>
        <button
          onClick={() => refetch()}
          className="px-4 py-2 bg-indigo-600 text-white rounded-md hover:bg-indigo-700"
        >
          Retry
        </button>
      </div>
    );
  }

  return (
    <div className="h-screen flex flex-col">
      {/* Header */}
      <div className="bg-white border-b px-6 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <Network className="w-6 h-6 text-indigo-600" />
            <h1 className="text-2xl font-bold text-gray-900">Service Dependencies</h1>
          </div>
          <div className="flex items-center gap-4">
            {/* Search */}
            <div className="relative">
              <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 w-4 h-4 text-gray-400" />
              <input
                type="text"
                placeholder="Search services..."
                value={searchTerm}
                onChange={(e) => setSearchTerm(e.target.value)}
                className="pl-10 pr-4 py-2 border rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500"
              />
            </div>

            {/* Layout selector */}
            <select
              value={layoutType}
              onChange={(e) => setLayoutType(e.target.value)}
              className="px-4 py-2 border rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500"
            >
              <option value="hierarchical">Hierarchical</option>
              <option value="circular">Circular</option>
              <option value="grid">Grid</option>
            </select>

            <button
              onClick={() => refetch()}
              className="px-4 py-2 bg-indigo-600 text-white rounded-md hover:bg-indigo-700"
            >
              Refresh
            </button>
          </div>
        </div>
      </div>

      {/* Graph + Sidebar */}
      <div className="flex-1 flex overflow-hidden">
        {/* React Flow Graph */}
        <div className="flex-1 relative">
          <ReactFlow
            nodes={filteredNodes}
            edges={edges}
            onNodesChange={onNodesChange}
            onEdgesChange={onEdgesChange}
            onNodeClick={onNodeClick}
            nodeTypes={nodeTypes}
            fitView
            attributionPosition="bottom-left"
          >
            <Background />
            <Controls />
            <MiniMap
              nodeColor={(node) => {
                if (highlighted.has(node.id)) {
                  return '#6366f1';
                }
                return healthColors[node.data.health] || healthColors.unknown;
              }}
            />
            <Panel position="top-left" className="bg-white p-4 rounded-md shadow-md">
              <div className="text-sm font-medium mb-2">Legend</div>
              <div className="space-y-1">
                <div className="flex items-center gap-2 text-xs">
                  <div className="w-3 h-3 rounded-full" style={{ backgroundColor: healthColors.healthy }} />
                  <span>Healthy</span>
                </div>
                <div className="flex items-center gap-2 text-xs">
                  <div className="w-3 h-3 rounded-full" style={{ backgroundColor: healthColors.degraded }} />
                  <span>Degraded</span>
                </div>
                <div className="flex items-center gap-2 text-xs">
                  <div className="w-3 h-3 rounded-full" style={{ backgroundColor: healthColors.unhealthy }} />
                  <span>Unhealthy</span>
                </div>
                <div className="flex items-center gap-2 text-xs">
                  <div className="w-3 h-3 rounded-full" style={{ backgroundColor: healthColors.stopped }} />
                  <span>Stopped</span>
                </div>
              </div>
            </Panel>
          </ReactFlow>
        </div>

        {/* Dependency Panel Sidebar */}
        {selectedNode && (
          <DependencyPanel
            serviceName={selectedNode}
            onClose={() => setSelectedNode(null)}
          />
        )}
      </div>
    </div>
  );
}
