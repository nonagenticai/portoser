import React, { useEffect, useState } from 'react';
import PropTypes from 'prop-types';
import api from '../../api/client';
import { safeToFixed } from '../../utils/formatters';

export default function ServiceAssignmentPanel({ service, onClose }) {
  const [selectedDeviceId, setSelectedDeviceId] = useState(null);
  const [devices, setDevices] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        setLoading(true);
        setError(null);
        // Authenticated client — raw fetch bypasses the Bearer interceptor.
        const { data } = await api.get('/devices');
        if (!cancelled) setDevices(data.devices || []);
      } catch (err) {
        if (!cancelled) setError(err.message);
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, []);

  const recommendedDevice = devices[0];

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
      <div className="bg-white rounded-lg w-full max-w-4xl max-h-[90vh] overflow-y-auto">
        <div className="p-6 border-b">
          <div className="flex justify-between items-center">
            <div>
              <h2 className="text-2xl font-bold">Move Service: {service.name}</h2>
              <p className="text-sm text-gray-600">Current: {service.current_device || 'Unassigned'}</p>
            </div>
            <button onClick={onClose} className="text-gray-400 hover:text-gray-600 text-2xl">×</button>
          </div>
        </div>

        <div className="p-6 space-y-6">
          {recommendedDevice && (
            <div>
              <div className="flex items-center gap-2 mb-3">
                <span className="text-yellow-500">✨</span>
                <h3 className="text-lg font-semibold">Recommended (AI-Powered)</h3>
              </div>
              <DeviceOption
                device={recommendedDevice}
                isRecommended
                isSelected={selectedDeviceId === recommendedDevice.id}
                onSelect={() => setSelectedDeviceId(recommendedDevice.id)}
              />
            </div>
          )}

          <div>
            <h3 className="text-lg font-semibold mb-3">All Available Devices</h3>
            {loading ? (
              <p className="text-sm text-gray-500">Loading devices…</p>
            ) : error ? (
              <p className="text-sm text-red-600">Failed to load devices: {error}</p>
            ) : devices.length === 0 ? (
              <p className="text-sm text-gray-500">No devices available.</p>
            ) : (
              <div className="space-y-3">
                {devices.slice(1).map(device => (
                  <DeviceOption
                    key={device.id}
                    device={device}
                    isSelected={selectedDeviceId === device.id}
                    onSelect={() => setSelectedDeviceId(device.id)}
                  />
                ))}
              </div>
            )}
          </div>
        </div>

        <div className="p-6 border-t flex justify-between">
          <button onClick={onClose} className="btn">Cancel</button>
          <div className="flex gap-3">
            <button disabled={!selectedDeviceId} className="btn">Preview</button>
            <button disabled={!selectedDeviceId} className="btn btn-primary">Deploy Now</button>
          </div>
        </div>
      </div>
    </div>
  );
}

ServiceAssignmentPanel.propTypes = {
  service: PropTypes.shape({
    name: PropTypes.string.isRequired,
    current_device: PropTypes.string,
  }).isRequired,
  onClose: PropTypes.func.isRequired,
};

function DeviceOption({ device, isRecommended, isSelected, onSelect }) {
  const getResourceColor = (percent) => {
    if (percent >= 90) return 'text-red-600';
    if (percent >= 70) return 'text-yellow-600';
    return 'text-green-600';
  };

  return (
    <div
      onClick={onSelect}
      className={`border-2 rounded-lg p-4 cursor-pointer transition-all ${
        isSelected ? 'border-blue-500 bg-blue-50' :
        isRecommended ? 'border-green-300 bg-green-50' :
        'border-gray-200 hover:border-gray-300'
      }`}
    >
      <div className="flex justify-between items-start mb-3">
        <div>
          <div className="flex items-center gap-2">
            <h4 className="font-semibold">{device.name}</h4>
            {isRecommended && (
              <span className="px-2 py-0.5 bg-green-100 text-green-800 text-xs rounded-full">
                Best Match
              </span>
            )}
          </div>
          <p className="text-sm text-gray-600">{device.ip_address} | {device.os} | {device.arch}</p>
        </div>
        <div className="text-right">
          <div className="text-2xl font-bold">{device.score}</div>
          <div className="text-xs text-gray-500">/ 100</div>
        </div>
      </div>

      <div className="grid grid-cols-3 gap-3 mb-3 text-sm">
        <div>
          <span className="text-gray-600">CPU:</span>
          <span className={`ml-1 font-medium ${getResourceColor(device.cpu_percent || 0)}`}>
            {safeToFixed(device.cpu_percent, 1)}%
          </span>
        </div>
        <div>
          <span className="text-gray-600">Memory:</span>
          <span className={`ml-1 font-medium ${getResourceColor(device.memory_percent || 0)}`}>
            {safeToFixed(device.memory_percent, 1)}%
          </span>
        </div>
        <div>
          <span className="text-gray-600">Disk:</span>
          <span className={`ml-1 font-medium ${getResourceColor(device.disk_percent || 0)}`}>
            {safeToFixed(device.disk_percent, 1)}%
          </span>
        </div>
      </div>

      {device.conflicts?.length > 0 && (
        <div className="space-y-2 mb-3">
          {device.conflicts.map((conflict, i) => (
            <div key={i} className={`p-2 rounded text-sm ${
              conflict.severity === 'error' ? 'bg-red-50 text-red-800' : 'bg-yellow-50 text-yellow-800'
            }`}>
              {conflict.message}
            </div>
          ))}
        </div>
      )}

      {isRecommended && device.recommendations && (
        <div className="pt-3 border-t">
          <div className="text-xs font-medium mb-1">Why recommended:</div>
          <ul className="text-xs text-gray-600 space-y-1">
            {device.recommendations.map((rec, i) => (
              <li key={i}>• {rec}</li>
            ))}
          </ul>
        </div>
      )}

      <button className="btn-sm w-full mt-3">Select Device</button>
    </div>
  );
}

DeviceOption.propTypes = {
  device: PropTypes.shape({
    id: PropTypes.string.isRequired,
    name: PropTypes.string.isRequired,
    ip_address: PropTypes.string,
    os: PropTypes.string,
    arch: PropTypes.string,
    cpu_percent: PropTypes.number,
    memory_percent: PropTypes.number,
    disk_percent: PropTypes.number,
    score: PropTypes.number,
    conflicts: PropTypes.arrayOf(PropTypes.shape({
      severity: PropTypes.string,
      message: PropTypes.string,
    })),
    recommendations: PropTypes.arrayOf(PropTypes.string),
  }).isRequired,
  isRecommended: PropTypes.bool,
  isSelected: PropTypes.bool.isRequired,
  onSelect: PropTypes.func.isRequired,
};
