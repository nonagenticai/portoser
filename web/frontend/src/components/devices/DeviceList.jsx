import React, { useState, useEffect } from 'react';
import api from '../../api/client';
import DeviceCard from './DeviceCard';
import AddDeviceModal from './AddDeviceModal';
import ErrorBoundary from './ErrorBoundary';

export default function DeviceList() {
  const [showAddDevice, setShowAddDevice] = useState(false);
  const [statusFilter, setStatusFilter] = useState('all');
  const [searchQuery, setSearchQuery] = useState('');
  const [devices, setDevices] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  const stats = devices.reduce(
    (acc, d) => {
      const isOnline = d.status === 'online' || d.status === 'connected';
      acc[isOnline ? 'online' : 'offline']++;
      acc.totalServices += Number(d.service_count ?? d.services?.length ?? 0);
      const cpu = Number(d.metrics?.cpu_percent);
      if (Number.isFinite(cpu)) {
        acc._cpuSum += cpu;
        acc._cpuCount++;
      }
      return acc;
    },
    { online: 0, offline: 0, totalServices: 0, _cpuSum: 0, _cpuCount: 0 }
  );
  stats.avgCpu = stats._cpuCount ? +(stats._cpuSum / stats._cpuCount).toFixed(1) : 0;

  useEffect(() => {
    const fetchDevices = async () => {
      try {
        setLoading(true);
        setError(null);
        // Use the authenticated client (raw fetch bypassed the Bearer
        // interceptor and 401'd when KEYCLOAK_ENABLED=true).
        const { data } = await api.get('/devices');
        setDevices(data.devices || []);
      } catch (err) {
        console.error('Failed to fetch devices:', err);
        setError(err.message);
        setDevices([]);
      } finally {
        setLoading(false);
      }
    };

    fetchDevices();
  }, []);

  return (
    <div className="p-6">
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-3xl font-bold">Device Management</h1>
          <p className="text-sm text-gray-500 mt-1">Manage and monitor all devices</p>
        </div>
        <button onClick={() => setShowAddDevice(true)} className="btn btn-primary">
          + Add Device
        </button>
      </div>

      <div className="grid grid-cols-4 gap-4 mb-6">
        <div className="bg-white p-4 rounded-lg border">
          <div className="text-sm text-gray-500">Online</div>
          <div className="text-2xl font-bold">{stats.online}</div>
        </div>
        <div className="bg-white p-4 rounded-lg border">
          <div className="text-sm text-gray-500">Offline</div>
          <div className="text-2xl font-bold">{stats.offline}</div>
        </div>
        <div className="bg-white p-4 rounded-lg border">
          <div className="text-sm text-gray-500">Services</div>
          <div className="text-2xl font-bold">{stats.totalServices}</div>
        </div>
        <div className="bg-white p-4 rounded-lg border">
          <div className="text-sm text-gray-500">Avg CPU</div>
          <div className="text-2xl font-bold">{stats.avgCpu}%</div>
        </div>
      </div>

      <div className="flex items-center gap-4 mb-6">
        <select value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)} className="input">
          <option value="all">All Status</option>
          <option value="online">Online</option>
          <option value="offline">Offline</option>
        </select>
        <input
          type="text"
          placeholder="Search devices..."
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          className="input w-64"
        />
      </div>

      {loading && (
        <div className="text-center py-12">
          <div className="inline-block animate-spin rounded-full h-12 w-12 border-b-2 border-blue-500"></div>
          <p className="mt-4 text-gray-600">Loading devices...</p>
        </div>
      )}

      {error && (
        <div className="bg-red-50 border border-red-200 rounded-lg p-4 mb-6">
          <p className="text-red-800">Error loading devices: {error}</p>
        </div>
      )}

      {!loading && !error && devices.length === 0 && (
        <div className="text-center py-12">
          <p className="text-gray-500 mb-4">No devices found</p>
          <button onClick={() => setShowAddDevice(true)} className="btn btn-primary">
            Add Your First Device
          </button>
        </div>
      )}

      {!loading && devices.length > 0 && (
        <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-6">
          {devices.map(device => (
            <ErrorBoundary key={device.id}>
              <DeviceCard device={device} />
            </ErrorBoundary>
          ))}
        </div>
      )}

      {showAddDevice && <AddDeviceModal onClose={() => setShowAddDevice(false)} />}
    </div>
  );
}
