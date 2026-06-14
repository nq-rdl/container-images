import java.net.*;
import java.io.*;

public class TlsProbe {
    public static void main(String[] args) throws Exception {
        String target = System.getenv("TARGET_URL");
        if (target == null) { System.err.println("no TARGET_URL"); System.exit(4); }
        // Proxy + trustStore come from JAVA_TOOL_OPTIONS (platform-set); see C-4.
        HttpURLConnection c = (HttpURLConnection) new URL(target).openConnection();
        c.setConnectTimeout(10000);
        c.setReadTimeout(10000);
        try (InputStream in = c.getInputStream()) {
            in.read();  // force the TLS handshake to complete
            System.out.println("status=" + c.getResponseCode());
            System.exit(0);
        } catch (javax.net.ssl.SSLException e) {
            System.err.println("ssl: " + e.getMessage());
            System.exit(2);
        }
    }
}
