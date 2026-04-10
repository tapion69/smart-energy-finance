module.exports = {
    uiPort: process.env.PORT || 1892,

    mqttReconnectTime: 15000,
    serialReconnectTime: 15000,

    debugMaxLength: 1000,

    flowFile: 'flows.json',
    flowFilePretty: true,

    userDir: '/data',

    nodesDir: '/opt/node_modules',

    credentialSecret: false,

    functionGlobalContext: {
        fs: require('fs'),
        path: require('path'),
        os: require('os'),
        crypto: require('crypto')
    },

    contextStorage: {
        default: {
            module: 'memory'
        },
        persistent: {
            module: 'localfilesystem'
        }
    },

    exportGlobalContextKeys: false,

    logging: {
        console: {
            level: 'info',
            metrics: false,
            audit: false
        }
    },

    editorTheme: {
        projects: {
            enabled: false
        }
    },

    diagnostics: {
        enabled: false,
        ui: false
    },

    runtimeState: {
        enabled: false,
        ui: false
    }
};
