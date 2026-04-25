package com.manulife.powerbi

import org.junit.Test
import org.junit.Before
import static org.junit.Assert.*

/**
 * Unit tests for PowerBIDeploymentConfig.
 *
 * Run with the standard pipeline-lib test harness:
 *   ./gradlew test --tests com.manulife.powerbi.PowerBIDeploymentConfigTest
 *
 * These tests do not require a Jenkins instance — they validate the pure-Groovy
 * input handling of the config class, which is the highest-value test surface
 * because it's where consuming app teams will hit problems first.
 */
class PowerBIDeploymentConfigTest {

    @Test
    void validConfigPasses() {
        def cfg = new PowerBIDeploymentConfig(
            targetEnv: 'DEV',
            appName: 'KH-D2C'
        )
        cfg.validate()
        assertEquals('DEV', cfg.targetEnv)
        assertEquals('KH-D2C', cfg.appName)
        // Derived defaults applied
        assertEquals('pbi-kh-d2c-dev', cfg.credentialPrefix)
        assertEquals('com/manulife/powerbi/config/KH-D2C-DEV.json', cfg.configResourcePath)
        // Static defaults applied
        assertEquals('reports', cfg.reportFolder)
        assertEquals('windows-powerbi', cfg.agentLabel)
        assertEquals(45, cfg.timeoutMinutes)
        assertTrue(cfg.rebindDataset)
        assertFalse(cfg.refreshDataset)
        assertFalse(cfg.dryRun)
    }

    @Test(expected = IllegalArgumentException)
    void missingTargetEnvFails() {
        new PowerBIDeploymentConfig(appName: 'KH-D2C').validate()
    }

    @Test(expected = IllegalArgumentException)
    void missingAppNameFails() {
        new PowerBIDeploymentConfig(targetEnv: 'DEV').validate()
    }

    @Test(expected = IllegalArgumentException)
    void invalidTargetEnvFails() {
        new PowerBIDeploymentConfig(
            targetEnv: 'STAGING',  // not in DEV/TEST/UAT/PROD
            appName: 'KH-D2C'
        ).validate()
    }

    @Test(expected = IllegalArgumentException)
    void unknownArgFails() {
        new PowerBIDeploymentConfig(
            targetEnv: 'DEV',
            appName: 'KH-D2C',
            doTheThing: true   // typo / unknown
        )
    }

    @Test(expected = IllegalArgumentException)
    void invalidAppNameFails() {
        new PowerBIDeploymentConfig(
            targetEnv: 'DEV',
            appName: 'KH D2C!'   // spaces, special chars
        ).validate()
    }

    @Test(expected = IllegalArgumentException)
    void timeoutTooLowFails() {
        new PowerBIDeploymentConfig(
            targetEnv: 'DEV',
            appName: 'KH-D2C',
            timeoutMinutes: 1
        ).validate()
    }

    @Test
    void overridesApplied() {
        def cfg = new PowerBIDeploymentConfig(
            targetEnv:        'PROD',
            appName:          'KH-D2C',
            credentialPrefix: 'pbi-shared-prod',  // override the derived default
            timeoutMinutes:   90,
            refreshDataset:   true,
            dryRun:           true
        )
        cfg.validate()
        assertEquals('pbi-shared-prod', cfg.credentialPrefix)
        assertEquals(90, cfg.timeoutMinutes)
        assertTrue(cfg.refreshDataset)
        assertTrue(cfg.dryRun)
    }
}
