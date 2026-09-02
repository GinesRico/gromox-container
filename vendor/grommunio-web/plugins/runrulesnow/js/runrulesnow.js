Ext.namespace('Zarafa.plugins.runrulesnow');
Ext.namespace('Zarafa.plugins.runrulesnow.data');

Zarafa.plugins.runrulesnow.data.ResponseHandler = Ext.extend(Zarafa.core.data.AbstractResponseHandler, {
	doRun: function(response)
	{
		var info = response || {};
		var msg = info.display_message ||
			String.format(
				_('Rules processed. Scanned: {0}, matched: {1}, moved: {2}, skipped rules: {3}.'),
				info.scanned || 0,
				info.matched || 0,
				info.moved || 0,
				info.skipped_rules || 0
			);

		Ext.MessageBox.alert(_('Run rules now'), msg);
	},

	doError: function(response)
	{
		var msg = _('Could not run rules.');
		if (response && response.info && response.info.display_message) {
			msg = response.info.display_message;
		}
		Ext.MessageBox.alert(_('Run rules now'), msg);
	}
});

Zarafa.plugins.runrulesnow.Plugin = Ext.extend(Zarafa.core.Plugin, {
	initPlugin: function()
	{
		Zarafa.plugins.runrulesnow.Plugin.superclass.initPlugin.apply(this, arguments);
		Zarafa.plugins.runrulesnow.activePlugin = this;
		this.patchRulesContextMenu();
		this.patchFolderSelectionLink();
		this.patchPublicFolderUnreadFilter();
		this.bindPublicFolderUnreadUpdates();
		this.registerInsertionPoint('settings.rules.action.last', this.createRulesButton, this);
		this.registerInsertionPoint('settings.rules.action.last', this.createRulesSearchField, this);
		this.registerInsertionPoint('settings.rules.action.last', this.createRulesSearchPreviousButton, this);
		this.registerInsertionPoint('settings.rules.action.last', this.createRulesSearchNextButton, this);
		this.registerInsertionPoint('main.maintabbar.left', this.createRulesMainTab, this);
		Ext.defer(this.ensureRulesMainTab, 500, this);
		Ext.defer(this.applyPublicFolderUnreadFilter, 1000, this);
	},

	bindPublicFolderUnreadUpdates: function()
	{
		var hierarchyStore = container.getHierarchyStore && container.getHierarchyStore();

		if (this.publicUnreadUpdateTask || !hierarchyStore) {
			return;
		}

		this.publicUnreadUpdateTask = new Ext.util.DelayedTask(function() {
			this.applyPublicFolderUnreadFilter();
		}, this);

		hierarchyStore.on('update', this.schedulePublicFolderUnreadFilter, this);
		hierarchyStore.on('datachanged', this.schedulePublicFolderUnreadFilter, this);
		hierarchyStore.on('load', this.schedulePublicFolderUnreadFilter, this);
	},

	schedulePublicFolderUnreadFilter: function()
	{
		if (this.publicUnreadUpdateTask) {
			this.publicUnreadUpdateTask.delay(300);
		}
	},

	getPublicUnreadFilterKey: function()
	{
		var user = container.getUser && container.getUser();
		var username = user && user.getUserName ? user.getUserName() : 'default';

		return 'runrulesnow.publicFolders.unreadOnly.' + username;
	},

	isPublicUnreadFilterEnabled: function()
	{
		try {
			return window.localStorage.getItem(this.getPublicUnreadFilterKey()) === '1';
		} catch (e) {
			return false;
		}
	},

	setPublicUnreadFilterEnabled: function(enabled)
	{
		try {
			window.localStorage.setItem(this.getPublicUnreadFilterKey(), enabled ? '1' : '0');
		} catch (e) {
			// Ignore storage errors; the current view can still be updated.
		}

		this.applyPublicFolderUnreadFilter();
	},

	isPublicFolderRecord: function(folder)
	{
		var store;

		if (!folder || !folder.getMAPIStore) {
			return false;
		}

		store = folder.getMAPIStore();
		return store && store.isPublicStore && store.isPublicStore();
	},

	hasUnreadInLoadedBranch: function(folder)
	{
		var children;
		var i;

		if (!folder) {
			return false;
		}

		if ((folder.get('content_unread') || 0) > 0) {
			return true;
		}

		children = folder.getChildren ? folder.getChildren() : [];
		for (i = 0; i < children.length; i++) {
			if (this.hasUnreadInLoadedBranch(children[i])) {
				return true;
			}
		}

		return false;
	},

	applyPublicFolderNodeVisibility: function(node)
	{
		var folder = node && node.getFolder ? node.getFolder() : null;
		var ui = node && node.getUI ? node.getUI() : null;
		var wrap = ui && ui.getEl ? ui.getEl() : null;
		var visible;

		if (!folder || !wrap || !this.isPublicFolderRecord(folder)) {
			return;
		}

		visible = !this.isPublicUnreadFilterEnabled() ||
			folder.isIPMSubTree() ||
			this.hasUnreadInLoadedBranch(folder);

		Ext.get(wrap).setDisplayed(visible);
	},

	applyPublicFolderUnreadFilter: function()
	{
		var trees = Ext.ComponentMgr.all.filterBy(function(component) {
			return component.isXType && component.isXType('zarafa.hierarchytree');
		});

		trees.each(function(tree) {
			var root = tree.getRootNode && tree.getRootNode();
			if (!root || !root.cascade) {
				return;
			}

			root.cascade(function(node) {
				this.applyPublicFolderNodeVisibility(node);
			}, this);
		}, this);
	},

	patchPublicFolderUnreadFilter: function()
	{
		var menuClass = Zarafa.hierarchy && Zarafa.hierarchy.ui ? Zarafa.hierarchy.ui.ContextMenu : null;
		var nodeClass = Zarafa.hierarchy && Zarafa.hierarchy.ui ? Zarafa.hierarchy.ui.FolderNode : null;
		var treeClass = Zarafa.hierarchy && Zarafa.hierarchy.ui ? Zarafa.hierarchy.ui.Tree : null;
		var originalCreateContextMenuItems;
		var originalNodeUpdate;
		var originalTreeUpdateAll;

		if (menuClass && !menuClass.prototype.runRulesNowPublicUnreadMenuPatch) {
			originalCreateContextMenuItems = menuClass.prototype.createContextMenuItems;

			Ext.override(menuClass, {
				runRulesNowPublicUnreadMenuPatch: true,

				createContextMenuItems: function(config)
				{
					var items = originalCreateContextMenuItems.apply(this, arguments);
					var plugin = Zarafa.plugins.runrulesnow.activePlugin;
					var insertIndex = items.length - 1;
					var i;

					for (i = 0; i < items.length; i++) {
						if (items[i].name === 'shareFolder') {
							insertIndex = i;
							break;
						}
					}

					items.splice(insertIndex, 0, {
						text: 'Mostrar solo carpetas publicas con no leidos',
						iconCls: 'icon_mail_unread',
						handler: function() {
							plugin.setPublicUnreadFilterEnabled(!plugin.isPublicUnreadFilterEnabled());
						},
						beforeShow: function(item, record) {
							var isPublic = plugin && plugin.isPublicFolderRecord(record);

							item.setDisabled(!isPublic);
							if (isPublic) {
								item.setText(plugin.isPublicUnreadFilterEnabled() ?
									'Mostrar todas las carpetas publicas' :
									'Mostrar solo carpetas publicas con no leidos');
							}
						}
					}, {
						xtype: 'menuseparator'
					});

					return items;
				}
			});
		}

		if (nodeClass && !nodeClass.prototype.runRulesNowPublicUnreadNodePatch) {
			originalNodeUpdate = nodeClass.prototype.update;

			Ext.override(nodeClass, {
				runRulesNowPublicUnreadNodePatch: true,

				update: function(deep)
				{
					var result = originalNodeUpdate.apply(this, arguments);
					var plugin = Zarafa.plugins.runrulesnow.activePlugin;

					if (plugin) {
						plugin.applyPublicFolderNodeVisibility(this);
					}

					return result;
				}
			});
		}

		if (treeClass && !treeClass.prototype.runRulesNowPublicUnreadTreePatch) {
			originalTreeUpdateAll = treeClass.prototype.updateAll;

			Ext.override(treeClass, {
				runRulesNowPublicUnreadTreePatch: true,

				updateAll: function()
				{
					var result = originalTreeUpdateAll.apply(this, arguments);
					var plugin = Zarafa.plugins.runrulesnow.activePlugin;

					if (plugin) {
						Ext.defer(plugin.applyPublicFolderUnreadFilter, 50, plugin);
					}

					return result;
				}
			});
		}
	},

	patchRulesContextMenu: function()
	{
		var menuClass = Zarafa.common && Zarafa.common.rules && Zarafa.common.rules.ui ?
			Zarafa.common.rules.ui.RulesContextMenu : null;

		if (!menuClass || menuClass.prototype.runRulesNowStorePatch) {
			return;
		}

		Ext.override(menuClass, {
			runRulesNowStorePatch: true,

			getContextStoreEntryId: function()
			{
				var record = Array.isArray(this.records) ? this.records[0] : this.records;
				var defaultStore = container.getHierarchyStore().getDefaultStore();

				if (record && record.get && !Ext.isEmpty(record.get('store_entryid'))) {
					return record.get('store_entryid');
				}

				if (this.mailStore && !Ext.isEmpty(this.mailStore.storeEntryId)) {
					return this.mailStore.storeEntryId;
				}

				return defaultStore ? defaultStore.get('store_entryid') : null;
			},

			prepareContextRulesStore: function(callback)
			{
				var storeEntryId = this.getContextStoreEntryId();

				if (Ext.isEmpty(storeEntryId)) {
					callback.call(this, this.store);
					return;
				}

				this.store = new Zarafa.common.rules.data.RulesStore({
					storeEntryId: storeEntryId,
					autoLoad: false
				});
				this.store.on('save', this.onSaveRecord, this);
				this.store.load({
					callback: function() {
						callback.call(this, this.store);
					},
					scope: this
				});
			},

			openContextRuleRecord: function(ruleRecord)
			{
				this.prepareContextRulesStore(function(store) {
					store.add(ruleRecord);
					Zarafa.common.Actions.openRulesEditContent(ruleRecord, {
						removeRecordOnCancel: true,
						autoSave: true
					});
				});
			},

			onCreateRule: function()
			{
				this.hide();
				this.openContextRuleRecord(this.createRuleRecord());
			},

			onCreateRuleForSender: function(button)
			{
				this.hide();

				var mailRecord = this.records[0];
				var ruleRecord;
				var userStore;
				var definitions;
				var condition;
				var action;

				if (!mailRecord.isOpened()) {
					this.openRecord(mailRecord, button ? button.name : 'ruleForSender');
					return;
				}

				ruleRecord = this.createRuleRecord();
				userStore = mailRecord.getSubStore('reply-to');
				definitions = this.getDefinitions(
					Zarafa.common.rules.data.ConditionFlags.RECEIVED_FROM,
					Zarafa.common.rules.data.ActionFlags.MOVE
				);
				condition = definitions.conditionDefinition({store: userStore});
				action = definitions.actionDefinition();
				ruleRecord.set('rule_condition', condition);
				ruleRecord.set('rule_actions', action);

				this.openContextRuleRecord(ruleRecord);
			},

			onCreateRuleForRecipient: function(button)
			{
				this.hide();

				var mailRecord = this.records[0];
				var defaultUserEntryId;
				var userStore;
				var recepientSubStore;
				var ruleRecord;
				var definitions;
				var condition;
				var action;

				if (!mailRecord.isOpened()) {
					this.openRecord(mailRecord, button ? button.name : 'ruleForRecipient');
					return;
				}

				defaultUserEntryId = mailRecord.get('received_by_entryid');
				if (Ext.isEmpty(defaultUserEntryId)) {
					defaultUserEntryId = mailRecord.get('sender_entryid');
				}

				userStore = new Zarafa.core.data.IPMRecipientStore();
				recepientSubStore = mailRecord.getSubStore('recipients');
				recepientSubStore.each(function(recipient) {
					var recipientEntryId = recipient.get('entryid');
					var isUserAlreadyAdded;
					if (!Zarafa.core.EntryId.compareEntryIds(defaultUserEntryId, recipientEntryId)) {
						isUserAlreadyAdded = !Ext.isEmpty(userStore.getById(recipientEntryId));
						if (!isUserAlreadyAdded) {
							userStore.add(recipient.copy(recipientEntryId));
						}
					}
				});

				ruleRecord = this.createRuleRecord();
				definitions = this.getDefinitions(
					Zarafa.common.rules.data.ConditionFlags.SENT_TO,
					Zarafa.common.rules.data.ActionFlags.MOVE
				);
				condition = definitions.conditionDefinition({store: userStore});
				action = definitions.actionDefinition();
				ruleRecord.set('rule_condition', condition);
				ruleRecord.set('rule_actions', action);

				this.openContextRuleRecord(ruleRecord);
			},

			onCreateRuleForSubject: function()
			{
				this.hide();

				var mailRecord = this.records[0];
				var subject = mailRecord.get('subject');
				var wordStore = new Ext.data.Store({ fields: [ 'words' ] });
				var ruleRecord = this.createRuleRecord();
				var definitions;
				var condition;
				var action;

				wordStore.add(new Ext.data.Record({ words: subject }));
				definitions = this.getDefinitions(
					Zarafa.common.rules.data.ConditionFlags.SUBJECT_WORDS,
					Zarafa.common.rules.data.ActionFlags.MOVE
				);
				condition = definitions.conditionDefinition({store: wordStore});
				action = definitions.actionDefinition();
				ruleRecord.set('rule_name', subject);
				ruleRecord.set('rule_condition', condition);
				ruleRecord.set('rule_actions', action);

				this.openContextRuleRecord(ruleRecord);
			}
		});
	},

	patchFolderSelectionLink: function()
	{
		var linkClass = Zarafa.common && Zarafa.common.rules && Zarafa.common.rules.dialogs ?
			Zarafa.common.rules.dialogs.FolderSelectionLink : null;

		if (!linkClass || linkClass.prototype.runRulesNowFolderPatch) {
			return;
		}

		Ext.override(linkClass, {
			runRulesNowFolderPatch: true,

			setAction: function(actionFlag, action)
			{
				var hierarchyStore = container.getHierarchyStore();
				var store;

				this.folder = undefined;
				this.isValid = false;

				if (action) {
					store = hierarchyStore.getById(action.storeentryid);
					if (store) {
						this.folder = store.getSubStore('folders').getById(action.folderentryid);
					}

					if (!this.folder && hierarchyStore.getFolder) {
						this.folder = hierarchyStore.getFolder(action.folderentryid);
					}

					// If the folder is not visible for the current logged-in user,
					// keep the stored action valid so saving the rule does not erase
					// its destination.
					this.isValid = Ext.isDefined(this.folder) || !Ext.isEmpty(action.folderentryid);
				}

				this.actionFlag = actionFlag;
				this.action = action;
				this.isModified = !Ext.isDefined(action);
				this.update(this.folder || (this.isValid ? { data: { display_name: _('Configured folder') } } : undefined));
			}
		});
	},

	createRulesMainTab: function()
	{
		return {
			xtype: 'zarafa.maintab',
			text: _('Rules'),
			tabOrderIndex: 55,
			id: 'mainmenu-button-runrulesnow-rules',
			handler: this.openRulesSettings,
			scope: this
		};
	},

	ensureRulesMainTab: function()
	{
		var tabbar = Ext.getCmp('zarafa-mainmenu');
		var button;
		var insertIndex = -1;
		var i;

		if (!tabbar || Ext.getCmp('mainmenu-button-runrulesnow-rules')) {
			return;
		}

		button = Ext.ComponentMgr.create(this.createRulesMainTab());
		if (tabbar.items) {
			for (i = 0; i < tabbar.items.getCount(); i++) {
				if (tabbar.items.itemAt(i).isXType && tabbar.items.itemAt(i).isXType('tbfill')) {
					insertIndex = i;
					break;
				}
			}
		}

		if (insertIndex >= 0 && tabbar.insert) {
			tabbar.insert(insertIndex, button);
		} else {
			tabbar.add(button);
		}

		tabbar.doLayout();
	},

	openRulesSettings: function()
	{
		var settingsContext = container.getContextByName('settings');

		if (!settingsContext) {
			Ext.MessageBox.alert(_('Rules'), _('Settings are not available.'));
			return;
		}

		if (container.getCurrentContext() !== settingsContext) {
			container.switchContext(settingsContext);
		}

		Ext.defer(function() {
			var categories = Ext.ComponentMgr.all.filterBy(function(component) {
				return component.isXType && component.isXType('zarafa.settingsrulecategory');
			});
			var category = categories && categories.getCount && categories.getCount() > 0 ? categories.itemAt(0) : null;

			if (category && category.id) {
				settingsContext.setView(category.id);
			}
		}, 350, this);
	},

	getActiveMailStoreEntryId: function()
	{
		var currentContext = container.getCurrentContext();
		var model = currentContext && currentContext.getModel ? currentContext.getModel() : null;
		var folders = model && model.getFolders ? model.getFolders() : null;
		var records = model && model.getSelectedRecords ? model.getSelectedRecords() : null;
		var folder;

		if (folders && folders.length > 0) {
			folder = folders[0];
			if (folder && folder.get && !Ext.isEmpty(folder.get('store_entryid'))) {
				return folder.get('store_entryid');
			}
		}

		if (records && records.length > 0 && records[0].get && !Ext.isEmpty(records[0].get('store_entryid'))) {
			return records[0].get('store_entryid');
		}

		return null;
	},

	selectRulesStore: function(storeEntryId)
	{
		var panels;
		var rulesPanel;
		var combo;
		var store;

		if (Ext.isEmpty(storeEntryId)) {
			return;
		}

		panels = Ext.ComponentMgr.all.filterBy(function(component) {
			return component.isXType && component.isXType('zarafa.rulespanel');
		});
		rulesPanel = panels && panels.getCount && panels.getCount() > 0 ? panels.itemAt(0) : null;
		if (!rulesPanel) {
			return;
		}

		combo = rulesPanel.findByType ? rulesPanel.findByType('combo')[0] : null;
		store = combo && combo.getStore ? combo.getStore() : null;
		if (store && store.findExact('value', storeEntryId) === -1) {
			return;
		}

		if (combo) {
			combo.setValue(storeEntryId);
		}
		if (rulesPanel.loadUserStore) {
			rulesPanel.loadUserStore(storeEntryId);
		}
	},

	createRulesButton: function()
	{
		return {
			xtype: 'button',
			text: _('Run now'),
			tooltip: _('Run enabled move rules on messages already in this Inbox.'),
			handler: this.onRunRulesNow,
			scope: this
		};
	},

	createRulesSearchField: function()
	{
		return {
			xtype: 'textfield',
			width: 220,
			emptyText: _('Search rule name...'),
			enableKeyEvents: true,
			style: 'margin-left: 8px;',
			listeners: {
				keyup: {
					fn: this.onRulesSearch,
					buffer: 150,
					scope: this
				},
				specialkey: function(field, event) {
					if (event.getKey && event.getKey() === event.ESC) {
						field.setValue('');
						this.onRulesSearch(field);
					}
				},
				scope: this
			}
		};
	},

	createRulesSearchPreviousButton: function()
	{
		return {
			xtype: 'button',
			text: _('Prev'),
			tooltip: _('Select previous matching rule.'),
			handler: function(button) {
				this.selectSearchMatch(button, -1);
			},
			scope: this
		};
	},

	createRulesSearchNextButton: function()
	{
		return {
			xtype: 'button',
			text: _('Next'),
			tooltip: _('Select next matching rule.'),
			handler: function(button) {
				this.selectSearchMatch(button, 1);
			},
			scope: this
		};
	},

	getRuleName: function(record)
	{
		var name = record.get('rule_name');
		if (!Ext.isEmpty(name)) {
			return name;
		}

		var props = record.get('props');
		if (props && !Ext.isEmpty(props.rule_name)) {
			return props.rule_name;
		}

		return '';
	},

	onRulesSearch: function(field)
	{
		var grid = field.findParentByType('zarafa.rulesgrid');
		var store = grid && grid.getStore ? grid.getStore() : null;
		var value = (field.getValue() || '').toLowerCase();

		if (!store) {
			return;
		}

		// Never leave the rules store filtered: grommunio saves only records
		// currently present in this store when the user clicks Apply.
		store.clearFilter();
		if (value === '') {
			return;
		}
	},

	selectSearchMatch: function(component, direction)
	{
		var grid = component.findParentByType('zarafa.rulesgrid');
		var store = grid && grid.getStore ? grid.getStore() : null;
		var toolbar = component.findParentByType('toolbar') || component.ownerCt;
		var field = toolbar && toolbar.findByType ? toolbar.findByType('textfield')[0] : null;
		var value = field ? (field.getValue() || '').toLowerCase() : '';
		var selectionModel;
		var current = -1;
		var count;
		var i;
		var index;

		if (!grid || !store || value === '') {
			return;
		}

		selectionModel = grid.getSelectionModel();
		if (selectionModel && selectionModel.getSelected) {
			index = store.indexOf(selectionModel.getSelected());
			current = index >= 0 ? index : -1;
		}

		count = store.getCount();
		for (i = 1; i <= count; i++) {
			index = (current + (direction * i) + count) % count;
			if (this.getRuleName(store.getAt(index)).toLowerCase().indexOf(value) !== -1) {
				if (selectionModel && selectionModel.selectRow) {
					selectionModel.selectRow(index);
				}
				if (grid.getView && grid.getView().focusRow) {
					grid.getView().focusRow(index);
				}
				if (field && field.focus) {
					field.focus(false, 50);
				}
				return;
			}
		}
	},

	onRunRulesNow: function(button)
	{
		var grid = button.findParentByType('zarafa.rulesgrid');
		var rulesStore = grid && grid.getStore ? grid.getStore() : null;
		var storeEntryId = rulesStore ? rulesStore.storeEntryId : null;

		if (Ext.isEmpty(storeEntryId)) {
			Ext.MessageBox.alert(_('Run rules now'), _('Could not determine the selected mailbox.'));
			return;
		}

		Ext.MessageBox.prompt(
			_('Run rules now'),
			_('Process messages received since date (YYYY-MM-DD):'),
			function(btn, value) {
				if (btn !== 'ok') {
					return;
				}

				value = Ext.isEmpty(value) ? '2026-01-01' : value;
				Ext.MessageBox.wait(_('Running rules...'), _('Run rules now'));

				container.getRequest().singleRequest(
					'runrulesnowmodule',
					'run',
					{
						store_entryid: storeEntryId,
						since_date: value,
						move: true
					},
					new Zarafa.plugins.runrulesnow.data.ResponseHandler()
				);
			},
			this,
			false,
			'2026-01-01'
		);
	}
});

Zarafa.onReady(function() {
	container.registerPlugin(new Zarafa.core.PluginMetaData({
		name: 'runrulesnow',
		displayName: _('Run Rules Now'),
		allowUserDisable: false,
		pluginConstructor: Zarafa.plugins.runrulesnow.Plugin
	}));
});
