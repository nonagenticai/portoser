import React, { useState } from 'react';
import PropTypes from 'prop-types';

export default function AddDeviceModal({ onClose }) {
  const [step, setStep] = useState(1);
  const [deviceName, setDeviceName] = useState('');
  const [tags, setTags] = useState([]);
  const [tagInput, setTagInput] = useState('');
  const [bootstrapCommand, setBootstrapCommand] = useState('');
  const [copied, setCopied] = useState(false);

  const handleGenerate = () => {
    const central = window.location.host;
    const proto = window.location.protocol;
    const cmd =
      `curl -fsSL ${proto}//${central}/bootstrap.sh | ` +
      `PORTOSER_CENTRAL=${window.location.hostname} bash`;
    setBootstrapCommand(cmd);
    setStep(2);
  };

  const handleCopy = () => {
    navigator.clipboard.writeText(bootstrapCommand);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const handleAddTag = () => {
    if (tagInput && !tags.includes(tagInput)) {
      setTags([...tags, tagInput]);
      setTagInput('');
    }
  };

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
      <div className="bg-white rounded-lg w-full max-w-2xl max-h-[90vh] overflow-y-auto">
        <div className="p-6 border-b">
          <div className="flex justify-between items-center">
            <h2 className="text-2xl font-bold">Add New Device</h2>
            <button onClick={onClose} className="text-gray-400 hover:text-gray-600 text-2xl">×</button>
          </div>
        </div>

        <div className="p-6">
          {step === 1 && (
            <div className="space-y-4">
              <div>
                <label className="block text-sm font-medium mb-2">Device Name (optional)</label>
                <input
                  type="text"
                  value={deviceName}
                  onChange={(e) => setDeviceName(e.target.value)}
                  placeholder="e.g., MacBook-Pro-2021"
                  className="input w-full"
                />
              </div>

              <div>
                <label className="block text-sm font-medium mb-2">Tags (optional)</label>
                <div className="flex gap-2">
                  <input
                    type="text"
                    value={tagInput}
                    onChange={(e) => setTagInput(e.target.value)}
                    onKeyPress={(e) => e.key === 'Enter' && handleAddTag()}
                    placeholder="e.g., production"
                    className="input flex-1"
                  />
                  <button onClick={handleAddTag} className="btn">Add</button>
                </div>
                {tags.length > 0 && (
                  <div className="mt-2 flex flex-wrap gap-2">
                    {tags.map(tag => (
                      <span key={tag} className="px-3 py-1 bg-blue-100 text-blue-800 rounded-full text-sm">
                        {tag}
                        <button onClick={() => setTags(tags.filter(t => t !== tag))} className="ml-2">×</button>
                      </span>
                    ))}
                  </div>
                )}
              </div>

              <button onClick={handleGenerate} className="btn btn-primary w-full">
                Generate Bootstrap Command
              </button>
            </div>
          )}

          {step === 2 && (
            <div className="space-y-4">
              <div>
                <h3 className="text-lg font-semibold mb-2">Run Command on Target Device</h3>
                <p className="text-sm text-gray-600 mb-4">
                  Copy and run this command on your new device:
                </p>
                <div className="relative">
                  <pre className="bg-gray-900 text-gray-100 p-4 rounded-lg text-sm overflow-x-auto">
                    {bootstrapCommand}
                  </pre>
                  <button onClick={handleCopy} className="absolute top-2 right-2 btn-sm">
                    {copied ? 'Copied!' : 'Copy'}
                  </button>
                </div>
              </div>

              <div className="bg-blue-50 border border-blue-200 rounded-lg p-4">
                <p className="text-sm text-blue-800">
                  The new device must be able to reach this controller over the network.
                  Once <code>bootstrap.sh</code> finishes, the device will register itself via
                  <code> POST /api/devices/register</code> and appear in the list below.
                </p>
              </div>

              <button onClick={() => setStep(3)} className="btn btn-primary w-full">
                I&rsquo;ve run the command
              </button>
            </div>
          )}

          {step === 3 && (
            <div className="space-y-4">
              <h3 className="text-lg font-semibold mb-2">Verifying Connection</h3>
              <div className="space-y-3">
                <div className="flex items-center gap-2">
                  <div className="w-5 h-5 bg-green-500 rounded-full flex items-center justify-center text-white text-xs">✓</div>
                  <span className="text-sm">Token generated</span>
                </div>
                <div className="flex items-center gap-2">
                  <div className="w-5 h-5 border-2 border-gray-300 rounded-full"></div>
                  <span className="text-sm">Device connected</span>
                </div>
                <div className="flex items-center gap-2">
                  <div className="w-5 h-5 border-2 border-gray-300 rounded-full"></div>
                  <span className="text-sm">Agent installed</span>
                </div>
              </div>
            </div>
          )}
        </div>

        <div className="p-6 border-t flex justify-end">
          <button onClick={onClose} className="btn">Close</button>
        </div>
      </div>
    </div>
  );
}

AddDeviceModal.propTypes = {
  onClose: PropTypes.func.isRequired,
};
