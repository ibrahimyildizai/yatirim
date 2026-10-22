#!/usr/bin/env bash
# YtFolder: Android klasör seçme eklentisi (app.html bunu kullanır).
# build.yml içinde "npx cap sync android" satırından SONRA çalışır.
set -e

MA=$(find android/app/src/main/java -name MainActivity.java | head -n1)
[ -n "$MA" ] || { echo "MainActivity.java bulunamadi"; exit 1; }
DIR=$(dirname "$MA")
PKG=$(grep -m1 '^package ' "$MA" | sed 's/package \(.*\);.*/\1/' | tr -d '\r')
echo "Paket: $PKG"

cat > "$DIR/YtFolderPlugin.java" <<'JAVA'
package __PKG__;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.provider.DocumentsContract;

import androidx.activity.result.ActivityResult;
import androidx.documentfile.provider.DocumentFile;

import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.annotation.ActivityCallback;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.PluginMethod;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

@CapacitorPlugin(name = "YtFolder")
public class YtFolderPlugin extends Plugin {

    private static final String SUB = "YatirimTakip";

    @PluginMethod
    public void pick(PluginCall call) {
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION
                | Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);
        startActivityForResult(call, i, "pickResult");
    }

    @ActivityCallback
    private void pickResult(PluginCall call, ActivityResult result) {
        if (call == null) return;
        if (result.getResultCode() != Activity.RESULT_OK || result.getData() == null
                || result.getData().getData() == null) {
            call.reject("cancelled");
            return;
        }
        Uri u = result.getData().getData();
        try {
            getContext().getContentResolver().takePersistableUriPermission(u,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        } catch (Exception ignored) { }
        String name = "";
        try { name = DocumentsContract.getTreeDocumentId(u); } catch (Exception ignored) { }
        JSObject o = new JSObject();
        o.put("uri", u.toString());
        o.put("name", name);
        call.resolve(o);
    }

    private DocumentFile root(PluginCall call) throws Exception {
        String uri = call.getString("uri");
        if (uri == null) throw new Exception("klasor yok");
        DocumentFile r = DocumentFile.fromTreeUri(getContext(), Uri.parse(uri));
        if (r == null || !r.canWrite()) throw new Exception("klasore yazma izni yok");
        return r;
    }

    private DocumentFile sub(DocumentFile root, boolean create) {
        DocumentFile d = root.findFile(SUB);
        if ((d == null || !d.isDirectory()) && create) d = root.createDirectory(SUB);
        return d;
    }

    @PluginMethod
    public void write(PluginCall call) {
        try {
            String name = call.getString("name");
            String data = call.getString("data");
            String mime = call.getString("mime", "application/json");
            if (name == null || data == null) throw new Exception("eksik veri");
            DocumentFile d = sub(root(call), true);
            if (d == null) throw new Exception("YatirimTakip klasoru olusturulamadi");
            DocumentFile old = d.findFile(name);
            if (old != null) old.delete();
            DocumentFile f = d.createFile(mime, name);
            if (f == null) throw new Exception("dosya olusturulamadi");
            try (OutputStream os = getContext().getContentResolver().openOutputStream(f.getUri(), "wt")) {
                os.write(data.getBytes(StandardCharsets.UTF_8));
            }
            JSObject o = new JSObject();
            o.put("uri", f.getUri().toString());
            call.resolve(o);
        } catch (Exception e) {
            call.reject(String.valueOf(e.getMessage()), e);
        }
    }

    @PluginMethod
    public void list(PluginCall call) {
        try {
            DocumentFile d = sub(root(call), false);
            JSArray arr = new JSArray();
            if (d != null && d.isDirectory()) {
                for (DocumentFile f : d.listFiles()) {
                    if (!f.isFile()) continue;
                    JSObject o = new JSObject();
                    o.put("name", f.getName());
                    o.put("uri", f.getUri().toString());
                    o.put("time", f.lastModified());
                    o.put("size", f.length());
                    arr.put(o);
                }
            }
            JSObject r = new JSObject();
            r.put("files", arr);
            call.resolve(r);
        } catch (Exception e) {
            call.reject(String.valueOf(e.getMessage()), e);
        }
    }

    @PluginMethod
    public void read(PluginCall call) {
        try {
            Uri u = Uri.parse(call.getString("uri"));
            try (InputStream is = getContext().getContentResolver().openInputStream(u);
                 ByteArrayOutputStream bo = new ByteArrayOutputStream()) {
                byte[] b = new byte[8192];
                int n;
                while ((n = is.read(b)) > 0) bo.write(b, 0, n);
                JSObject o = new JSObject();
                o.put("data", bo.toString("UTF-8"));
                call.resolve(o);
            }
        } catch (Exception e) {
            call.reject(String.valueOf(e.getMessage()), e);
        }
    }

    @PluginMethod
    public void open(PluginCall call) {
        try {
            DocumentFile r = root(call);
            DocumentFile d = sub(r, false);
            Uri target = (d != null ? d.getUri() : r.getUri());
            Intent i = new Intent(Intent.ACTION_VIEW);
            i.setDataAndType(target, DocumentsContract.Document.MIME_TYPE_DIR);
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
            getContext().startActivity(i);
            call.resolve();
        } catch (Exception e) {
            call.reject(String.valueOf(e.getMessage()), e);
        }
    }
}
JAVA
sed -i "s/__PKG__/$PKG/" "$DIR/YtFolderPlugin.java"

cat > "$MA" <<JAVA2
package $PKG;

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(YtFolderPlugin.class);
        super.onCreate(savedInstanceState);
    }
}
JAVA2

grep -q "androidx.documentfile" android/app/build.gradle || \
  sed -i '0,/^dependencies {/s//dependencies {\n    implementation "androidx.documentfile:documentfile:1.0.1"/' android/app/build.gradle

echo "YtFolder eklendi"
