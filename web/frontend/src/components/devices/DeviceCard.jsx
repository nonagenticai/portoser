import React, { useState } from 'react';
import PropTypes from 'prop-types';
import { safeToFixed } from '../../utils/formatters';

export default function DeviceCard({ device }) {
  const [expanded, setExpanded] = useState(false);

  const getDeviceIcon = (type) => {
    const icons = { macbook: '💻', mac_studio: '🖥️', mac_mini: '🔲', vm: '☁️' };
    return icons[type] || '🖥️';
  };

  const getStatusColor = (status) => {
    const colors = {
      online: 'bg-green-500',
      offline: 'bg-gray-500',
      warning: 'bg-yellow-500',
      error: 'bg-red-500'
    };
    return colors[status] || 'bg-gray-500';
  };

  const getResourceColor = (percent) => {
    if (percent >= 90) return 'bg-red-500';
    if (percent >= 70) return 'bg-yellow-500';
    return 'bg-green-500';
  };

  return (
    <div className="bg-white rounded-lg border-2 border-gray-200 hover:border-blue-500 transition-all">
      <div className="p-4 border-b">
        <div className="flex items-start justify-between">
          <div className="flex items-center gap-3">
            <div className="text-4xl">{getDeviceIcon(device.device_type)}</div>
            <div>
              <h3 className="font-semibold">{device.name}</h3>
              <p className="text-sm text-gray-500">{device.ip_address}</p>
              <p className="text-xs text-gray-400">{device.os} | {device.arch}</p>
            </div>
          </div>
          <div className={`w-3 h-3 rounded-full ${getStatusColor(device.status)}`}></div>
        </div>
        <div className="mt-2 text-xs text-gray-500">
          Last seen: {new Date(device.last_seen).toLocaleString()}
        </div>
      </div>

      <div className="p-4 border-b">
        <button onClick={() => setExpanded(!expanded)} className="w-full text-left text-sm font-medium mb-2">
          Resources {expanded ? '▼' : '▶'}
        </button>
        {expanded ? (
          <div className="space-y-2">
            <div>
              <div className="flex justify-between text-xs mb-1">
                <span>CPU</span>
                <span>{safeToFixed(device.cpu_percent, 1)}%</span>
              </div>
              <div className="h-2 bg-gray-200 rounded-full overflow-hidden">
                <div className={`h-full ${getResourceColor(device.cpu_percent || 0)}`} style={{width: `${Math.min(device.cpu_percent || 0, 100)}%`}}></div>
              </div>
            </div>
            <div>
              <div className="flex justify-between text-xs mb-1">
                <span>Memory</span>
                <span>{safeToFixed(device.memory_percent, 1)}%</span>
              </div>
              <div className="h-2 bg-gray-200 rounded-full overflow-hidden">
                <div className={`h-full ${getResourceColor(device.memory_percent || 0)}`} style={{width: `${Math.min(device.memory_percent || 0, 100)}%`}}></div>
              </div>
            </div>
            <div>
              <div className="flex justify-between text-xs mb-1">
                <span>Disk</span>
                <span>{safeToFixed(device.disk_percent, 1)}%</span>
              </div>
              <div className="h-2 bg-gray-200 rounded-full overflow-hidden">
                <div className={`h-full ${getResourceColor(device.disk_percent || 0)}`} style={{width: `${Math.min(device.disk_percent || 0, 100)}%`}}></div>
              </div>
            </div>
          </div>
        ) : (
          <div className="h-2 bg-gray-200 rounded-full overflow-hidden">
            <div className={`h-full ${getResourceColor(device.cpu_percent || 0)}`} style={{width: `${Math.min(device.cpu_percent || 0, 100)}%`}}></div>
          </div>
        )}
      </div>

      <div className="p-4 border-b">
        <div className="text-sm font-medium mb-2">Services ({device.service_count || 0})</div>
        {device.services?.length > 0 ? (
          <div className="grid grid-cols-2 gap-2">
            {device.services.slice(0, 4).map(service => (
              <div key={service.name} className="p-2 bg-gray-50 rounded text-xs">
                <div className="font-medium">{service.name}</div>
                <div className="text-gray-500">CPU: {safeToFixed(service.cpu_percent, 1)}%</div>
              </div>
            ))}
          </div>
        ) : (
          <div className="text-center py-4 text-sm text-gray-400">No services</div>
        )}
      </div>

      <div className="p-4 flex gap-2">
        <button className="btn-sm flex-1">Restart</button>
        <button className="btn-sm flex-1">Logs</button>
        <button className="btn-sm flex-1">Terminal</button>
      </div>
    </div>
  );
}

DeviceCard.propTypes = {
  device: PropTypes.shape({
    id: PropTypes.string,
    name: PropTypes.string.isRequired,
    ip_address: PropTypes.string,
    os: PropTypes.string,
    arch: PropTypes.string,
    device_type: PropTypes.string,
    status: PropTypes.string,
    last_seen: PropTypes.string,
    cpu_percent: PropTypes.number,
    memory_percent: PropTypes.number,
    disk_percent: PropTypes.number,
    service_count: PropTypes.number,
    services: PropTypes.arrayOf(PropTypes.shape({
      name: PropTypes.string,
      cpu_percent: PropTypes.number,
    })),
  }).isRequired,
};
