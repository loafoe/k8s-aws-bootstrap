{{/*
The hsp-addons data, once: the hsp-addons ConfigMap (Kyverno's ECR pull-through policy reads it)
carries these as JSON strings, the hsp-addons EnvironmentConfig (Crossplane compositions read it)
as structured data.
*/}}
{{- define "hspAddons.pullThroughRegistries" -}}
["docker-hub","quay","github","k8s","ecr-public"]
{{- end }}

{{- define "hspAddons.eks" -}}
{
  "oidcProviderArn": "{{ .Values.environmentConfig.bootstrap.oidcProviderArn }}",
  "oidcProvider": "{{ .Values.environmentConfig.bootstrap.oidcProvider }}",
  "clusterName": "{{ .Values.environmentConfig.bootstrap.clusterName }}",
  "clusterId": "{{ .Values.environmentConfig.bootstrap.clusterName }}",
  "resourcePrefix": "{{ .Values.environmentConfig.bootstrap.resourcePrefix }}",
  "clusterFqdn": "{{ .Values.environmentConfig.bootstrap.clusterFqdn }}",
  "clusterEndpoint": "{{ .Values.environmentConfig.bootstrap.clusterEndpoint }}"
}
{{- end }}

{{- define "hspAddons.servicesVpc" -}}
{
  "id": "{{ .Values.environmentConfig.bootstrap.awsVpcId }}",
  "privateSubnetIds": {{ .Values.environmentConfig.bootstrap.awsPrivateSubnetIds }},
  "subnetGroups": {
    "database": {{ .Values.environmentConfig.bootstrap.awsRdsSubnetGroup }},
    "redshift": {{ .Values.environmentConfig.bootstrap.awsRedshiftSubnetGroup }},
    "elasticache": {{ .Values.environmentConfig.bootstrap.awsElasticacheSubnetGroup }}
  },
  "securityGroups": {
    "database": {{ .Values.environmentConfig.bootstrap.awsRdsSecurityGroups }},
    "redshift": {{ .Values.environmentConfig.bootstrap.awsRedshiftSecurityGroups }},
    "elasticache": {{ .Values.environmentConfig.bootstrap.awsElasticacheSecurityGroups }},
    "activemq": {{ .Values.environmentConfig.bootstrap.awsActivemqSecurityGroups }}
  }
}
{{- end }}

{{- define "hspAddons.tags" -}}
{
  "Environment": "{{ .Values.environmentConfig.bootstrap.resourcePrefix }}"
}
{{- end }}

{{/* A JSON object as YAML; a render error rather than a silently broken EnvironmentConfig */}}
{{- define "hspAddons.objectYaml" -}}
{{- $parsed := fromJson .json -}}
{{- if hasKey $parsed "Error" -}}
{{- fail (printf "hsp-addons %s is not valid JSON (%s): %s" .name (get $parsed "Error") .json) -}}
{{- end -}}
{{- toYaml $parsed -}}
{{- end }}
