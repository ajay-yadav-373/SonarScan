package com.awesome.testing.gui.browsermobproxy.utils;

import net.lightbody.bmp.BrowserMobProxyServer;
import net.lightbody.bmp.client.ClientUtil;
import net.lightbody.bmp.proxy.CaptureType;
import org.fluentlenium.adapter.junit.FluentTest;
import org.junit.After;
import org.junit.Before;
import org.openqa.selenium.Proxy;
import org.openqa.selenium.WebDriver;
import org.openqa.selenium.chrome.ChromeDriver;
import org.openqa.selenium.chrome.ChromeOptions;

import java.net.Inet4Address;
import java.net.UnknownHostException;

public class BrowserMobChrome extends FluentTest {

    private static final int BROWSER_MOB_PROXY_PORT = 9191;

    protected BrowserMobProxyServer server = new BrowserMobProxyServer();

    @Before
    public void startBMP() {
        server.start(BROWSER_MOB_PROXY_PORT);
        server.setHarCaptureTypes(CaptureType.getHeaderCaptureTypes());
    }

    @Override
    public WebDriver newWebDriver() {
        return new ChromeDriver(getChromeOptions());
    }

    private ChromeOptions getChromeOptions() {
        ChromeOptions options = new ChromeOptions();
        options.setProxy(getChromeProxySettings());
        return options;
    }

    private Proxy getChromeProxySettings() {
        Proxy seleniumProxy = ClientUtil.createSeleniumProxy(server);
        String hostIp = null;
        try {
            hostIp = Inet4Address.getLocalHost().getHostAddress();
        } catch (UnknownHostException e) {
            e.printStackTrace();
        }
        String proxyUrl = String.format("%s:%s", hostIp, BROWSER_MOB_PROXY_PORT);
        seleniumProxy.setHttpProxy(proxyUrl);
        seleniumProxy.setSslProxy(proxyUrl);

        return seleniumProxy;
    }

    @After
    public void stopBMP() {
        server.stop();
    }
}
