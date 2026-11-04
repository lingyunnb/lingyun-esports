allprojects {
    repositories {
        // 国内网络：阿里云镜像优先，再回退官方源
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 插件子项目（open_filex 等）写死 compileSdk 34/35，本机仅装 35/36/37 → 统一强制 36（androidx.activity 1.13 要求 ≥36）
subprojects {
    if (project == rootProject) return@subprojects
    val config: (Any) -> Unit = {
        try {
            extensions.configure(com.android.build.gradle.BaseExtension::class.java) {
                compileSdkVersion(36)
            }
        } catch (_: Exception) {
            // 非 android 模块跳过
        }
    }
    if (state.executed) config(Unit) else afterEvaluate { config(Unit) }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
