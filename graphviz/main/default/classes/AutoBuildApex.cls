public without sharing class AutoBuildApex implements AutoBuild.AutoBuilder {

    // a set of class names that are not used as field/object sources in normal operation
    private final Set<String> excluded = new Set<String>{
            'AutoBuild', 'AutoBuildApex', 'AutoBuildApexTests', 'AutoBuildDiagram', 'AutoBuildTrigger',
            'AutoBuildTriggerTests', 'BuilderSource', 'GraphVizForceController', 'GraphvizForceControllerTest',
            'ToolingAPI', 'ToolingAPITest', 'ToolingAPIMocks', 'UmlService',
            'egServerSideActionController', 'egServerSideActionControllerTest'
    };

    public List<BuilderSource> getSources() {

        List<BuilderSource> results = new List<BuilderSource>();

        Map<String, String> config = GraphVizForceController.getConfig();
        System.debug('Config:' + config);

        if (config.get('development mode') == NULL) {
            for (List<ApexClass> classes : [
                    SELECT Id, Name
                    FROM ApexClass
                    WHERE Name <> :excluded
                    ORDER BY NAME
            ]) {
                for (ApexClass clazz : classes) {
                    results.add(new BuilderSource(clazz.Name, clazz.Id));
                }
            }
        } else {
            for (List<ApexClass> classes : [
                    SELECT Id, Name
                    FROM ApexClass
                    ORDER BY NAME
            ]) {
                for (ApexClass clazz : classes) {
                    results.add(new BuilderSource(clazz.Name, clazz.Id));
                }
            }
        }
        return results;
    }

    private Class Payload {
        String requestId;
        String diagramId;
    }

    public AutoBuild.BuilderUpdate startSource(Id diagramId, BuilderSource source) {
        AutoBuild.BuilderUpdate result = new AutoBuild.BuilderUpdate();
        // kick off the compile request
        ToolingApi.ContainerAsyncRequest request = UmlService.compile(source.source);

        Payload payload = new Payload();
        payload.requestId = request.id;
        payload.diagramId = diagramId;

        result.payload = JSON.serialize(payload);
        result.status = AutoBuild.STATUS_WORKING;
        return result;
    }

    public AutoBuild.BuilderUpdate pollSource(Id diagramId, BuilderSource source, AutoBuild.BuilderUpdate prevUpdate) {
        AutoBuild.BuilderUpdate result = new AutoBuild.BuilderUpdate();
        Payload payload = (Payload) JSON.deserialize(prevUpdate.payload, Payload.class);
        ToolingApi.ContainerAsyncRequest request = UmlService.containerAsyncRequest(payload.requestId);
        result.status = request.state;
        if (request.state == 'Completed') {

            System.debug('reading completed symbol table for class: ' + source.source);
            ToolingApi.SymbolTable symbolTable = UmlService.symbolTable(request.metadataContainerId, source.source);

            AutoBuildDiagram diagram = new AutoBuildDiagram(payload.diagramId);

            Map<String, GraphVizForceController.ObjectWrapper> entityDescribesByName = diagram.getDescribeMap();

            // for every entity found in the Tooling API Symbol Table....
            for (ToolingAPI.ExternalReference reference : symbolTable.externalReferences) {
                String objectName = reference.name;

                AutoBuildDiagram.DiagramEntity diagramEntity = diagram.diagramEntitiesByName.get(objectName);

                // ensure there is an entity in the persisted diagram JSON
                if (diagramEntity == NULL) {

                    GraphVizForceController.ObjectWrapper entityDescribe = entityDescribesByName.get(objectName);

                    // only add Data Model references to diagram i.e. ignore references to List.class etc
                    if (entityDescribe != NULL) {

                        diagramEntity = new AutoBuildDiagram.DiagramEntity(entityDescribe);
                        diagram.addEntity(diagramEntity);

                        // for all field references found in the class...
                        Set<String> fieldsFromClass = new Set<String>();
                        for (ToolingAPI.ExternalSymbol symbol : reference.variables) {
                            fieldsFromClass.add(symbol.name);
                        }
                        // make the fields visible in the persisted diagram JSON entity
                        for (AutoBuildDiagram.DiagramAttribute diagramAttribute : diagramEntity.attributes) {
                            if (fieldsFromClass.contains(diagramAttribute.value)) {
                                diagramAttribute.visible = true;
                                diagramAttribute.selected = true;
                            }
                        }
                    }
                }
            }

            diagram.updateDiagram();

            // return the updated diagram
            result.diagramJSON = diagram.asJSON();
            result.status = AutoBuild.STATUS_COMPLETE;
        } else {
            result.payload = prevUpdate.payload; // pass back to client for use in next poll/update request
            result.status = AutoBuild.STATUS_WORKING;
        }
        return result;
    }

}